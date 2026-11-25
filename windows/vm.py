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
    devices = sorted((group / "devices").iterdir())
    for device in devices:
        kind = read(device / "class") or ""
        if not (kind.startswith("0x03") or kind == "0x040300"):
            raise ValueError(f"IOMMU group contains an unrelated device: {device.name}")
        if read(device / "boot_vga") == "1":
            raise ValueError("refusing the host's primary boot display")
        driver = device / "driver"
        if require_vfio and (not driver.is_symlink() or driver.resolve().name != "vfio-pci"):
            raise ValueError(f"{device.name} is not bound to vfio-pci; host lifecycle preparation is required")
    return group.resolve().name, [device.name for device in devices]


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


def container_args(image, storage, shared, *, oem=None, iso=None, devices=(), group=None, memory=8, cpus=4):
    if any("," in str(path) or "\n" in str(path) for path in [storage, shared, oem, iso] if path is not None):
        raise ValueError("Docker mount paths cannot contain commas or newlines")
    args = ["--user", "0", "--device", "/dev/kvm", "--device", "/dev/net/tun", "--cap-add", "NET_ADMIN",
            "--cpus", str(cpus), "--memory", f"{memory + 2}g", "--pids-limit", "1024",
            "--mount", f"type=bind,src={storage},dst=/storage",
            "--mount", f"type=bind,src={shared},dst=/shared",
            "--env", f"RAM_SIZE={memory}G", "--env", f"CPU_CORES={cpus}",
            "--env", "DISK_SIZE=64G", "--env", "VERSION=11e", "--env", "MANUAL=N"]
    if oem:
        args += ["--mount", f"type=bind,src={oem},dst=/oem,readonly"]
    if iso:
        args += ["--mount", f"type=bind,src={iso},dst=/custom.iso,readonly"]
    if devices:
        args += ["--device", "/dev/vfio/vfio", "--device", f"/dev/vfio/{group}",
                 "--env", "ARGUMENTS=" + " ".join(f"-device vfio-pci,host={device}" for device in devices)]
    return [*args, image]


def execute_vm(image, storage, shared, marker, timeout, **kwargs):
    name = "mesh-windows-" + uuid.uuid4().hex
    log = shared / "output/qemu.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    created = False
    try:
        docker("create", "--name", name, *container_args(image, storage, shared, **kwargs), stdout=subprocess.DEVNULL)
        created = True
        docker("start", name, stdout=subprocess.DEVNULL)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
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
                docker("stop", "--time", "120", name, stdout=subprocess.DEVNULL)
                with log.open("wb") as stream:
                    docker("logs", name, stdout=stream, stderr=subprocess.STDOUT)
            finally:
                docker("rm", "--force", name, stdout=subprocess.DEVNULL)
                docker("run", "--rm", "--user", "0", "--network", "none", "--entrypoint", "chown",
                       "--mount", f"type=bind,src={shared},dst=/work", image,
                       "-R", f"{os.getuid()}:{os.getgid()}", "/work", stdout=subprocess.DEVNULL)


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
               "tools_sha256": sha256(ROOT / "tools.json"), "files": storage_manifest(storage)}
    (work / "base.json").write_text(json.dumps(receipt, indent=2) + "\n")


def run(args):
    if not args.lease:
        raise ValueError("the caller must supply its exclusive host reservation identity")
    group, devices = gpu_devices(args.backend, args.gpu)
    base = args.base.resolve(strict=True)
    receipt = json.loads((base / "base.json").read_text())
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
    if shutil.disk_usage(work).free < 64 * 2**30:
        raise ValueError("guest execution requires at least 64 GiB free space")
    # Reflink where available; GNU cp preserves sparse files on other Linux
    # filesystems. The golden storage directory is never writable by the VM.
    subprocess.run(["cp", "--reflink=auto", "--sparse=always", "-a", "--no-preserve=ownership", str(base / "storage"), str(storage)], check=True)
    shutil.copytree(args.input.resolve(strict=True), shared / "input")
    result = shared / "output/result.json"
    execute_vm(args.image, storage, shared, result, args.timeout, devices=devices, group=group)
    value = json.loads(result.read_text(encoding="utf-8-sig"))
    if value.get("schema") != 1 or type(value.get("exit_code")) is not int or value["exit_code"] != 0:
        raise RuntimeError(f"Windows task failed: {value}")
    print(json.dumps({"schema": 1, "backend": args.backend, "gpu": args.gpu,
                      "lease": args.lease, "base_receipt_sha256": sha256(base / "base.json"), "result": value}))


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
    args = parser.parse_args()
    if hasattr(args, "image") and not re.fullmatch(r"(?:[^\s]+@)?sha256:[a-f0-9]{64}", args.image):
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
