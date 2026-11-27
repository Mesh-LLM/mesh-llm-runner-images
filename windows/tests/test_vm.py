import importlib.util
import argparse
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
        self.assertEqual(self.inspect(), (["12"], ["0000:01:00.0", "0000:01:00.1"]))

    def separate_audio(self):
        audio = self.device("0000:01:00.1", "0x040300", "0x10de")
        (self.group / 'devices' / audio.name).unlink()
        (audio / 'iommu_group').unlink()
        group = self.root / 'kernel/iommu_groups/20'
        (group / 'devices').mkdir(parents=True)
        (audio / 'iommu_group').symlink_to(group)
        (group / 'devices' / audio.name).symlink_to(audio)
        return group

    def test_includes_isolated_paired_audio_group(self):
        self.separate_audio()
        self.assertEqual(self.inspect(), (["12", "20"], ["0000:01:00.0", "0000:01:00.1"]))

    def test_rejects_unrelated_device_in_paired_audio_group(self):
        group = self.separate_audio()
        (group / 'devices/0000:01:00.2').symlink_to(self.gpu)
        with self.assertRaisesRegex(ValueError, 'audio group contains an unrelated'):
            self.inspect()

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

    def test_rocm_rejects_colliding_guest_addresses_before_native_handoff(self):
        (self.gpu / 'vendor').write_text('0x1002')
        self.device('0000:02:00.0', '0x030000', '0x1002')
        with self.assertRaisesRegex(ValueError, 'duplicate guest PCI'):
            vm.gpu_devices('rocm', self.gpu.name, sysfs=self.root, require_vfio=False)
        with self.assertRaisesRegex(ValueError, 'duplicate guest PCI'):
            vm.container_args('image', Path('/disk'), Path('/shared'),
                              devices=[self.gpu.name, '0000:02:00.0'], group=['12'], pcie=True)


class GuestLifecycle(unittest.TestCase):
    def test_cancellation_waits_for_guest_completion_before_teardown(self):
        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            (shared / 'input').mkdir()
            (shared / 'output').mkdir()
            (shared / 'input/driver.json').write_text(json.dumps({'backend': 'rocm'}))

            def finish(_):
                self.assertEqual((shared / 'input/cancel.request').read_text(), 'cancel\n')
                (shared / 'output/result.json').write_text('{"exit_code":1}')

            with patch.object(vm.time, 'sleep', side_effect=finish):
                vm.request_guest_cancel(shared)
            self.assertTrue((shared / 'output/result.json').is_file())
            (shared / 'input/cancel.request').unlink()
            vm.request_guest_cancel(shared)
            self.assertFalse((shared / 'input/cancel.request').exists())

    def test_cancellation_grace_is_bounded_when_guest_does_not_cooperate(self):
        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp)
            (shared / 'input').mkdir()
            (shared / 'input/driver.json').write_text(json.dumps({'backend': 'rocm'}))
            with patch.object(vm.time, 'monotonic', side_effect=[0, 1, 91]), \
                    patch.object(vm.time, 'sleep'):
                vm.request_guest_cancel(shared)
            self.assertTrue((shared / 'input/cancel.request').is_file())
            self.assertFalse((shared / 'output/result.json').exists())

    def test_task_receives_current_tool_pins_with_compatible_existing_base(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            base, inputs, work = root / 'base', root / 'input', root / 'attempt'
            (base / 'storage').mkdir(parents=True)
            (base / 'storage/data.qcow2').write_bytes(b'admitted-base')
            inputs.mkdir()
            (inputs / 'task.ps1').write_text('exit 0')
            (inputs / 'driver.exe').write_bytes(b'driver')
            (inputs / 'driver.json').write_text(json.dumps({
                'backend': 'cuda', 'device_id': '2c02', 'sha256': vm.sha256(inputs / 'driver.exe')}))
            (base / 'base.json').write_text(json.dumps({
                'schema': 1, 'launcher_image': 'image', 'files': vm.storage_manifest(base / 'storage'),
                'tools_sha256': 'old-base-tool-pins',
                'guest_bootstrap_sha256': vm.sha256(vm.ROOT / 'guest/Bootstrap.ps1')}))
            args = argparse.Namespace(lease='lease', backend='cuda', gpu='0000:01:00.0',
                                      base=base, input=inputs, work=work, image='image', timeout=60,
                                      rom=None, rom_sha256=None, audio_rom=None, audio_rom_sha256=None)

            def execute(image, storage, shared, result, timeout, **kwargs):
                pins = shared / 'input/tools.json'
                manifest = json.loads((shared / 'input/guest.json').read_text())
                self.assertEqual(manifest['files']['tools.json'], vm.sha256(pins))
                self.assertEqual(manifest['files']['TaskProcess.cs'],
                                 vm.sha256(shared / 'input/TaskProcess.cs'))
                self.assertEqual(pins.read_bytes(), (vm.ROOT / 'tools.json').read_bytes())
                result.parent.mkdir(exist_ok=True)
                result.write_text(json.dumps({'schema': 1, 'exit_code': 0}))

            with patch.object(vm, 'gpu_devices', return_value=(['12'], ['0000:01:00.0'])), \
                    patch.object(vm, 'read', return_value='0x2c02'), \
                    patch.object(vm.shutil, 'disk_usage', return_value=type('Disk', (), {'free': 100 * 2**30})()), \
                    patch.object(vm, 'overlay_storage'), patch.object(vm, 'execute_vm', execute):
                vm.run(args)

    def test_cached_base_without_current_bootstrap_cannot_boot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'base.json').write_text(json.dumps({'schema': 1}))
            args = argparse.Namespace(lease='reservation', backend='cuda', gpu='0000:01:00.0', base=root, rom=None, rom_sha256=None, audio_rom=None, audio_rom_sha256=None)
            with patch.object(vm, 'gpu_devices', return_value=('12', ['0000:01:00.0'])), \
                    patch.object(vm, 'docker') as docker:
                with self.assertRaisesRegex(ValueError, 'bootstrap differs'):
                    vm.run(args)
            docker.assert_not_called()

    def test_supplied_rom_is_hash_bound_and_mounted_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'vbios.rom'
            path.write_bytes(b'\x55\xaa' + b'fixture')
            digest = vm.sha256(path)
            self.assertEqual(vm.admit_rom(path, digest), path.resolve())
            with self.assertRaisesRegex(ValueError, 'checksum'):
                vm.admit_rom(path, '0' * 64)
            args = vm.container_args('image', Path('/storage'), Path('/shared'),
                                     devices=['0000:c2:00.0'], group=['19'], rom=path, rom_device='0000:c2:00.0')
            self.assertIn(f'type=bind,src={path},dst=/rom/vbios.rom,readonly', args)
            self.assertIn('romfile=/rom/vbios.rom', ' '.join(args))

    def test_rom_without_a_pin_or_assigned_gpu_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'requires its SHA'):
            vm.admit_rom(Path('/missing'), None)
        with self.assertRaisesRegex(ValueError, 'assigned GPU'):
            vm.container_args('image', Path('/storage'), Path('/shared'), rom=Path('/rom'), rom_device='0000:c2:00.0')

    def test_audio_rom_is_read_only_and_requires_paired_audio(self):
        options = dict(devices=['0000:c2:00.0', '0000:c2:00.1'], group=['19', '20'],
                       rom=Path('/gpu.rom'), rom_device='0000:c2:00.0', audio_rom=Path('/gop.rom'), pcie=True)
        args = vm.container_args('image', Path('/storage'), Path('/shared'), **options)
        self.assertIn('/dev/vfio/19', args)
        self.assertIn('/dev/vfio/20', args)
        self.assertIn('type=bind,src=/gop.rom,dst=/rom/audio.rom,readonly', args)
        self.assertIn('pcie-root-port,id=mesh-gpu', ' '.join(args))
        self.assertIn('host=0000:c2:00.0,bus=mesh-gpu,addr=0.0,multifunction=on,romfile=/rom/vbios.rom', ' '.join(args))
        self.assertIn('host=0000:c2:00.1,bus=mesh-gpu,addr=0.1,romfile=/rom/audio.rom', ' '.join(args))
        options['devices'] = ['0000:c2:00.0']
        with self.assertRaisesRegex(ValueError, 'paired audio function'):
            vm.container_args('image', Path('/storage'), Path('/shared'), **options)

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
        args = vm.container_args("sha256:" + "a" * 64, Path("/disk"), Path("/shared"), devices=["0000:01:00.0"], group=["12"])
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

    def test_leased_vm_creation_uses_the_recovery_fence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            storage, shared = root / 'storage', root / 'shared'
            storage.mkdir()
            marker = root / 'result.json'
            marker.write_text('{}')
            with patch.object(vm, 'docker', return_value=type('Result', (), {'stdout': 'false\n'})()) as docker, \
                    patch.object(vm.subprocess, 'run') as launch, \
                    patch.object(vm, 'restore_ownership'), patch.object(vm, 'request_guest_cancel'), \
                    patch.object(vm.shutil, 'disk_usage', return_value=type('Usage', (), {'free': 10 * 2**30})()):
                vm.execute_vm('image', storage, shared, marker, 60, lease='run_test',
                              devices=['0000:01:00.0'], group=['12'], rom_device='0000:01:00.0',
                              lifecycle_manager='/approved/manager')
            launch.assert_called_once()
            self.assertEqual(launch.call_args.args[0], ['/approved/manager', 'launch', '--lease', 'run_test',
                             '--gpu', '0000:01:00.0', '--launch-spec', str(root / 'launch.json')])
            spec = json.loads((root / 'launch.json').read_text())
            self.assertIn('mesh.windows.lease=run_test', spec['arguments'])
            self.assertFalse(any(call.args[0] in ('create', 'start') for call in docker.call_args_list))

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
