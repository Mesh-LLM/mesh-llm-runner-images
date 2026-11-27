#!/usr/bin/env python3
"""Prepare and run disposable Windows guests on an exclusively reserved Linux host."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BDF = re.compile(r"[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]\Z")
IMMUTABLE_IMAGE = re.compile(r"(?:[^\s]+@)?sha256:[a-f0-9]{64}\Z")
VENDORS = {"cuda": "0x10de", "rocm": "0x1002"}


def read(path):
    try:
        return path.read_text().strip()
    except OSError:
        return None


def sha256(path):
    state = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            state.update(block)
    return state.hexdigest()


def gpu_devices(backend, bdf, *, sysfs=Path("/sys"), require_vfio=True):
    if not BDF.fullmatch(bdf):
        raise ValueError("GPU must be a complete lowercase PCI address, e.g. 0000:01:00.0")
    gpu = sysfs / "bus/pci/devices" / bdf
    if read(gpu / "vendor") != VENDORS[backend] or not (read(gpu / "class") or "").startswith("0x03"):
        raise ValueError("GPU PCI identity does not match the requested backend")
    group = gpu / "iommu_group"
    if not group.is_symlink():
        raise ValueError("GPU has no IOMMU group")
    groups = {group.resolve().name}
    devices = sorted((group / "devices").iterdir())
    # Integrated graphics can isolate its HDMI audio function in a separate
    # group. Admit only the same slot's vendor-matched audio function, and
    # require that group's complete isolation too.
    audio = gpu.parent / (bdf[:-1] + "1")
    if (read(audio / "class") == "0x040300" and
            read(audio / "vendor") == VENDORS[backend] and audio.name not in {device.name for device in devices}):
        audio_group = audio / "iommu_group"
        if not audio_group.is_symlink():
            raise ValueError("GPU audio has no IOMMU group")
        audio_devices = sorted((audio_group / "devices").iterdir())
        if [device.name for device in audio_devices] != [audio.name]:
            raise ValueError("GPU audio group contains an unrelated device")
        groups.add(audio_group.resolve().name)
        devices.extend(audio_devices)
    for device in devices:
        kind = read(device / "class") or ""
        if not (kind.startswith("0x03") or kind == "0x040300"):
            raise ValueError(f"IOMMU group contains an unrelated device: {device.name}")
        if read(device / "boot_vga") == "1":
            raise ValueError("refusing the host's primary boot display")
        driver = device / "driver"
        if require_vfio and (not driver.is_symlink() or driver.resolve().name != "vfio-pci"):
            raise ValueError(f"{device.name} is not bound to vfio-pci; host lifecycle preparation is required")
    if backend == 'rocm' and len({device.name[-1] for device in devices}) != len(devices):
        raise ValueError('ROCm devices map to duplicate guest PCI function addresses')
    return sorted(groups), sorted({device.name for device in devices})


def doctor(args):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("Windows KVM guests require a Linux x86_64 host")
    group, devices = gpu_devices(args.backend, args.gpu, require_vfio=not args.inspect)
    result = {"schema": 1, "backend": args.backend, "gpu": args.gpu, "iommu_group": group,
              "devices": devices, "kvm_exists": Path("/dev/kvm").exists(),
              "vfio_required": not args.inspect}
    print(json.dumps(result, indent=2))
    if not result["kvm_exists"]:
        raise ValueError("/dev/kvm is missing")


def docker(*args, **kwargs):
    return subprocess.run(["docker", *map(str, args)], check=True, **kwargs)


def restore_ownership(image, shared):
    if shutil.which("findmnt"):
        filesystem = subprocess.run(
            ["findmnt", "--noheadings", "--output", "FSTYPE", "--target", str(shared)],
            check=True, capture_output=True, text=True,
        ).stdout.split()
        # NFS can squash both container root and the caller to a server UID.
        # Chown cannot normalize that mapping and may be rejected by the server.
        # Access and cleanup must use the export's mapped identity instead.
        if set(filesystem) - {"autofs"} in ({"nfs"}, {"nfs4"}):
            return
    docker("run", "--rm", "--user", "0", "--network", "none", "--entrypoint", "chown",
           "--mount", f"type=bind,src={shared},dst=/work", image,
           "-R", f"{os.getuid()}:{os.getgid()}", "/work", stdout=subprocess.DEVNULL)


def container_args(image, storage, shared, *, oem=None, iso=None, devices=(), group=None, memory=8, cpus=4, base=None, lease=None, rom=None, rom_device=None, audio_rom=None, pcie=False):
    if pcie and len({device[-1] for device in devices}) != len(devices):
        raise ValueError('ROCm devices map to duplicate guest PCI function addresses')
    if any("," in str(path) or "\n" in str(path) for path in [storage, shared, oem, iso, base, rom, audio_rom] if path is not None):
        raise ValueError("Docker mount paths cannot contain commas or newlines")
    args = ["--user", "0", "--device", "/dev/kvm", "--device", "/dev/net/tun", "--cap-add", "NET_ADMIN",
            "--cpus", str(cpus), "--memory", f"{memory + 2}g", "--pids-limit", "1024",
            "--mount", f"type=bind,src={storage},dst=/storage",
            "--mount", f"type=bind,src={shared},dst=/shared",
            "--env", f"RAM_SIZE={memory}G", "--env", f"CPU_CORES={cpus}",
            "--env", "DISK_SIZE=64G", "--env", "DISK_FMT=qcow2", "--env", "VERSION=11e", "--env", "MANUAL=N"]
    if oem:
        args += ["--mount", f"type=bind,src={oem},dst=/oem,readonly"]
    if iso:
        args += ["--mount", f"type=bind,src={iso},dst=/custom.iso,readonly"]
    if base:
        args += ["--mount", f"type=bind,src={base},dst=/base,readonly",
                 "--env", "DISK_FMT=qcow2", "--env", "DISK_IO=threads", "--env", "DISK_CACHE=writeback"]
    if lease:
        args += ["--label", "mesh.windows.lease=" + lease]
    if rom:
        if rom_device not in devices:
            raise ValueError("ROM must belong to the assigned GPU")
        args += ["--mount", f"type=bind,src={rom},dst=/rom/vbios.rom,readonly"]
    audio_device = rom_device[:-1] + "1" if rom_device else None
    if audio_rom:
        if not rom or audio_device not in devices:
            raise ValueError("audio ROM requires the assigned GPU ROM and paired audio function")
        args += ["--mount", f"type=bind,src={audio_rom},dst=/rom/audio.rom,readonly"]
    if devices:
        args += ["--device", "/dev/vfio/vfio"]
        for number in group:
            args += ["--device", f"/dev/vfio/{number}"]
        args += [
                 "--ulimit", "memlock=-1:-1",
                 "--env", "ARGUMENTS=" + ("-device pcie-root-port,id=mesh-gpu,chassis=30,slot=30 " if pcie else "") + " ".join(
                     f"-device vfio-pci,host={device}"
                     + (f",bus=mesh-gpu,addr=0.{device[-1]}" if pcie else "")
                     + (",multifunction=on" if pcie and device.endswith(".0") else "")
                     + (",romfile=/rom/vbios.rom" if rom and device == rom_device else "")
                     + (",romfile=/rom/audio.rom" if audio_rom and device == audio_device else "")
                     for device in devices)]
    return [*args, image]


def execute_vm(image, storage, shared, marker, timeout,
               lifecycle_manager='/usr/local/bin/mesh-windows-host', **kwargs):
    name = "mesh-windows-" + uuid.uuid4().hex
    log = shared / "output/qemu.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        arguments = container_args(image, storage, shared, **kwargs)
        if kwargs.get('lease'):
            spec = storage.parent / 'launch.json'
            spec.write_text(json.dumps({'name': name, 'arguments': arguments}))
            subprocess.run([str(lifecycle_manager), 'launch', '--lease', kwargs['lease'],
                            '--gpu', kwargs['rom_device'], '--launch-spec', str(spec)],
                           check=True, stdout=subprocess.DEVNULL)
            created = True
        else:
            docker("create", "--name", name, *arguments, stdout=subprocess.DEVNULL)
            created = True
            docker("start", name, stdout=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if shutil.disk_usage(storage).free < 2 * 2**30:
                raise RuntimeError("Windows guest disk reserve fell below 2 GiB")
            state = docker("inspect", "--format", "{{.State.Running}}", name, capture_output=True, text=True).stdout.strip()
            if state != "true":
                break
            time.sleep(3)
        else:
            raise RuntimeError("Windows guest exceeded its deadline")
        if not marker.is_file():
            raise RuntimeError("Windows guest exited without its required result marker")
    finally:
        if created:
            # Complete teardown before returning the allocation to the caller.
            # Never declare a VM successful while its QEMU process is still live.
            try:
                request_guest_cancel(shared)
                docker("stop", "--time", "120", name, stdout=subprocess.DEVNULL)
                with log.open("wb") as stream:
                    docker("logs", name, stdout=stream, stderr=subprocess.STDOUT)
            finally:
                docker("rm", "--force", name, stdout=subprocess.DEVNULL)
                restore_ownership(image, shared)


def request_guest_cancel(shared, timeout=90):
    if not (shared / 'input/driver.json').is_file() or (shared / 'output/result.json').exists():
        return
    try:
        profile = json.loads((shared / 'input/driver.json').read_text())
    except (OSError, ValueError):
        # Teardown still runs; the separate AMD release check retains quarantine.
        print('Could not read the guest cancellation profile', file=sys.stderr)
        return
    if not isinstance(profile, dict) or profile.get('backend') != 'rocm':
        return
    try:
        (shared / 'input/cancel.request').write_text('cancel\n')
    except OSError:
        print('Could not request guest cancellation; retain AMD release guard', file=sys.stderr)
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if (shared / 'output/result.json').is_file():
            return
        time.sleep(1)


def storage_manifest(storage):
    files = {}
    for path in sorted(storage.rglob("*")):
        if path.is_symlink() or (not path.is_dir() and not path.is_file()):
            raise ValueError(f"unsupported base image entry: {path.name}")
        if path.is_file():
            files[path.relative_to(storage).as_posix()] = sha256(path)
    if not files:
        raise ValueError("base disk storage is empty")
    return files


def work_directory(path):
    path = path.resolve()
    if any(part in str(path) for part in [",", "\n"]):
        raise ValueError("Docker mount paths cannot contain commas or newlines")
    path.mkdir(parents=True, exist_ok=False)
    (path / "shared/output").mkdir(parents=True)
    return path


def overlay_storage(image, base, storage):
    """Keep immutable Windows bytes on NFS and only guest writes on local disk."""
    disks = [name for name in ("data.img", "data.qcow2") if (base / name).is_file()]
    if len(disks) != 1:
        raise ValueError("base must contain exactly one Windows data disk")
    storage.mkdir()
    for path in base.iterdir():
        if path.name != disks[0]:
            if not path.is_file() or path.is_symlink():
                raise ValueError("unsupported base storage metadata")
            shutil.copyfile(path, storage / path.name)
    disk_format = "raw" if disks[0].endswith(".img") else "qcow2"
    docker("run", "--rm", "--user", str(os.getuid()), "--network", "none",
           "--mount", f"type=bind,src={base},dst=/base,readonly",
           "--mount", f"type=bind,src={storage},dst=/storage", "--entrypoint", "qemu-img", image,
           "create", "-f", "qcow2", "-F", disk_format, "-b", "/base/" + disks[0], "/storage/data.qcow2")


def admit_rom(path, digest):
    if not path and not digest:
        return None
    if not path or not digest or not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise ValueError("a supplied GPU ROM requires its SHA-256")
    path = path.resolve(strict=True)
    with path.open('rb') as stream:
        header = stream.read(2)
    if sha256(path) != digest or header != b'\x55\xaa':
        raise ValueError("GPU ROM checksum or option-ROM header mismatch")
    return path


def prepare(args):
    iso = args.iso.resolve(strict=True)
    if sha256(iso) != args.iso_sha256:
        raise ValueError("Windows ISO SHA-256 mismatch")
    if shutil.disk_usage(args.work.parent).free < 64 * 2**30:
        raise ValueError("base preparation requires at least 64 GiB free space")
    work = work_directory(args.work)
    storage, shared, oem = (work / name for name in ["storage", "shared", "oem"])
    storage.mkdir()
    shutil.copytree(ROOT / "guest", oem)
    shutil.copy(ROOT / "tools.json", oem / "tools.json")
    execute_vm(args.image, storage, shared, shared / "output/prepared.json", args.timeout, oem=oem, iso=iso)
    prepared = json.loads((shared / "output/prepared.json").read_text(encoding="utf-8-sig"))
    if prepared != {"schema": 1, "prepared": True}:
        raise ValueError("invalid Windows preparation marker")
    receipt = {"schema": 1, "launcher_image": args.image, "iso_sha256": args.iso_sha256,
               "tools_sha256": sha256(ROOT / "tools.json"),
               "guest_bootstrap_sha256": sha256(ROOT / "guest/Bootstrap.ps1"),
               "files": storage_manifest(storage)}
    (work / "base.json").write_text(json.dumps(receipt, indent=2) + "\n")


def run(args):
    if not args.lease:
        raise ValueError("the caller must supply its exclusive host reservation identity")
    rom = admit_rom(args.rom, args.rom_sha256)
    audio_rom = admit_rom(args.audio_rom, args.audio_rom_sha256)
    group, devices = gpu_devices(args.backend, args.gpu)
    base = args.base.resolve(strict=True)
    receipt = json.loads((base / "base.json").read_text())
    if receipt.get("guest_bootstrap_sha256") != sha256(ROOT / "guest/Bootstrap.ps1"):
        raise ValueError("base bootstrap differs from this recipe; prepare a compatible base")
    if receipt.get("schema") != 1 or receipt.get("files") != storage_manifest(base / "storage"):
        raise ValueError("Windows base disk receipt mismatch")
    if receipt["launcher_image"] != args.image:
        raise ValueError("launcher image differs from the one used to prepare the base")
    if not (args.input / "task.ps1").is_file():
        raise ValueError("input/task.ps1 is required")
    profile = json.loads((args.input / "driver.json").read_text())
    if profile.get("backend") != args.backend or profile.get("device_id") != read(Path("/sys/bus/pci/devices") / args.gpu / "device")[2:]:
        raise ValueError("driver profile does not match the assigned GPU")
    if profile.get("sha256") != sha256(args.input / "driver.exe"):
        raise ValueError("Windows driver checksum mismatch")
    work = work_directory(args.work)
    storage, shared = work / "storage", work / "shared"
    if shutil.disk_usage(work).free < 10 * 2**30:
        raise ValueError("guest execution requires at least 10 GiB free space")
    overlay_storage(args.image, base / "storage", storage)
    shutil.copytree(args.input.resolve(strict=True), shared / "input")
    guest_files = {}
    for name in ["RunTask.ps1", "InstallDriver.ps1", "GuestTask.ps1", "TaskProcess.cs"]:
        shutil.copyfile(ROOT / "guest" / name, shared / "input" / name)
        guest_files[name] = sha256(ROOT / "guest" / name)
    shutil.copyfile(ROOT / "tools.json", shared / "input/tools.json")
    guest_files["tools.json"] = sha256(ROOT / "tools.json")
    (shared / "input/guest.json").write_text(json.dumps({"schema": 1, "files": guest_files}))
    result = shared / "output/result.json"
    execute_vm(args.image, storage, shared, result, args.timeout, devices=devices, group=group,
               base=base / "storage", lease=args.lease, rom=rom, rom_device=args.gpu, audio_rom=audio_rom,
               pcie=args.backend == 'rocm',
               lifecycle_manager=getattr(args, 'lifecycle_manager', '/usr/local/bin/mesh-windows-host'))
    value = json.loads(result.read_text(encoding="utf-8-sig"))
    if value.get("schema") != 1 or type(value.get("exit_code")) is not int or value["exit_code"] != 0:
        raise RuntimeError(f"Windows task failed: {value}")
    print(json.dumps({"schema": 1, "backend": args.backend, "gpu": args.gpu,
                      "lease": args.lease, "base_receipt_sha256": sha256(base / "base.json"),
                      "rom_sha256": args.rom_sha256, "audio_rom_sha256": args.audio_rom_sha256, "result": value}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    diagnostic = commands.add_parser("doctor")
    diagnostic.add_argument("--backend", choices=VENDORS, required=True)
    diagnostic.add_argument("--gpu", required=True)
    diagnostic.add_argument("--inspect", action="store_true", help="inspect IOMMU topology without requiring VFIO binding")
    for name in ["prepare", "run"]:
        action = commands.add_parser(name)
        action.add_argument("--image", required=True, help="immutable container image ID or digest reference")
        action.add_argument("--work", required=True, type=Path, help="new persistent working directory")
        action.add_argument("--timeout", type=int, default=3600)
        if name == "prepare":
            action.add_argument("--iso", required=True, type=Path)
            action.add_argument("--iso-sha256", required=True)
        else:
            action.add_argument("--base", required=True, type=Path)
            action.add_argument("--input", required=True, type=Path)
            action.add_argument("--backend", choices=VENDORS, required=True)
            action.add_argument("--gpu", required=True)
            action.add_argument("--lease", required=True)
            action.add_argument('--lifecycle-manager', type=Path,
                                default=Path('/usr/local/bin/mesh-windows-host'))
            action.add_argument("--rom", type=Path, help="operator-supplied GPU option ROM")
            action.add_argument("--rom-sha256", help="SHA-256 of the supplied GPU option ROM")
            action.add_argument("--audio-rom", type=Path, help="supplied UEFI graphics ROM for the paired audio function")
            action.add_argument("--audio-rom-sha256", help="SHA-256 of the supplied audio-function ROM")
    args = parser.parse_args()
    if hasattr(args, "image") and not IMMUTABLE_IMAGE.fullmatch(args.image):
        raise ValueError("--image must be a digest reference or full sha256 Docker image ID")
    if hasattr(args, "timeout") and not 60 <= args.timeout <= 7200:
        raise ValueError("timeout must be between 60 and 7200 seconds")
    {"doctor": doctor, "prepare": prepare, "run": run}[args.command](args)


if __name__ == "__main__":
    def interrupted(*_):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        sys.exit(str(error) or "interrupted")
