import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "vm.py"
SPEC = importlib.util.spec_from_file_location("windows_vm", MODULE)
vm = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vm)


class PassthroughPolicy(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.group = self.root / "kernel/iommu_groups/12"
        (self.group / "devices").mkdir(parents=True)
        self.gpu = self.device("0000:01:00.0", "0x030000", "0x10de")

    def device(self, bdf, kind, vendor):
        device = self.root / "bus/pci/devices" / bdf
        device.mkdir(parents=True)
        for name, content in {"class": kind, "vendor": vendor, "boot_vga": "0"}.items():
            (device / name).write_text(content)
        (device / "iommu_group").symlink_to(self.group)
        (self.group / "devices" / bdf).symlink_to(device)
        (device / "driver").symlink_to(self.root / "bus/pci/drivers/vfio-pci")
        return device

    def inspect(self, **kwargs):
        return vm.gpu_devices("cuda", "0000:01:00.0", sysfs=self.root, **kwargs)

    def test_allows_gpu_and_audio_in_one_group(self):
        self.device("0000:01:00.1", "0x040300", "0x10de")
        self.assertEqual(self.inspect(), ("12", ["0000:01:00.0", "0000:01:00.1"]))

    def test_rejects_unrelated_device(self):
        self.device("0000:01:00.2", "0x0c0330", "0x10de")
        with self.assertRaisesRegex(ValueError, "unrelated"):
            self.inspect()

    def test_rejects_primary_display_and_wrong_vendor(self):
        (self.gpu / "boot_vga").write_text("1")
        with self.assertRaisesRegex(ValueError, "primary"):
            self.inspect()
        (self.gpu / "boot_vga").write_text("0")
        with self.assertRaisesRegex(ValueError, "identity"):
            vm.gpu_devices("rocm", self.gpu.name, sysfs=self.root)

    def test_inspection_cannot_satisfy_vfio_admission(self):
        (self.gpu / "driver").unlink()
        (self.gpu / "driver").symlink_to(self.root / "bus/pci/drivers/nvidia")
        self.inspect(require_vfio=False)
        with self.assertRaisesRegex(ValueError, "vfio-pci"):
            self.inspect()

    def test_rejects_pci_argument_injection(self):
        with self.assertRaisesRegex(ValueError, "PCI address"):
            vm.gpu_devices("cuda", "0000:01:00.0 -device bad", sysfs=self.root)


class GuestLifecycle(unittest.TestCase):
    def test_overlay_never_copies_the_golden_data_disk(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base = root / 'base'
            base.mkdir()
            (base / 'data.img').write_bytes(b'golden')
            (base / 'windows.vars').write_bytes(b'EFI')
            with patch.object(vm, 'docker') as docker:
                vm.overlay_storage('image', base, root / 'attempt')
            self.assertFalse((root / 'attempt/data.img').exists())
            self.assertEqual((root / 'attempt/windows.vars').read_bytes(), b'EFI')
            args = docker.call_args.args
            self.assertIn(f'type=bind,src={base},dst=/base,readonly', args)
            self.assertIn('/base/data.img', args)
            self.assertIn('/storage/data.qcow2', args)

    def test_nfs_cleanup_does_not_attempt_server_uid_chown(self):
        with patch.object(vm.shutil, "which", return_value="/usr/bin/findmnt"), \
                patch.object(vm.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "autofs\nnfs\n", "")), \
                patch.object(vm, "docker") as docker:
            vm.restore_ownership("image", Path("/nfs/shared"))
        docker.assert_not_called()

    def test_limits_devices_and_does_not_publish_ports(self):
        args = vm.container_args("sha256:" + "a" * 64, Path("/disk"), Path("/shared"), devices=["0000:01:00.0"], group="12")
        self.assertIn("/dev/vfio/12", args)
        self.assertIn("/dev/kvm", args)
        self.assertNotIn("--privileged", args)
        self.assertNotIn("--publish", args)
        self.assertNotIn("/var/run/docker.sock", " ".join(args))

    def test_missing_marker_fails_and_removes_container(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls = []

            def docker(*args, **kwargs):
                calls.append(args)
                return type("Completed", (), {"stdout": "false\n"})()

            with patch.object(vm, "docker", docker):
                with self.assertRaisesRegex(RuntimeError, "result marker"):
                    vm.execute_vm("image", root, root, root / "absent.json", 60)
            self.assertTrue(any(args[0] == "stop" for args in calls))
            self.assertTrue(any(args[0] == "rm" for args in calls))
            self.assertEqual(calls[-1][0], "run")

    def test_base_receipt_detects_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            disk = root / "disk.qcow2"
            disk.write_bytes(b"original")
            original = vm.storage_manifest(root)
            disk.write_bytes(b"changed")
            self.assertNotEqual(original, vm.storage_manifest(root))
            (root / "escape").symlink_to("/etc/passwd")
            with self.assertRaisesRegex(ValueError, "unsupported"):
                vm.storage_manifest(root)

    def test_tool_downloads_have_pinned_hashes(self):
        tools = json.loads((MODULE.parent / "tools.json").read_text())["tools"]
        for tool in tools:
            self.assertRegex(tool["sha256"], r"^[a-f0-9]{64}$")
            self.assertTrue(tool["url"].startswith("https://"))


if __name__ == "__main__":
    unittest.main()
