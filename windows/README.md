# Windows GPU smoke guests

This experimental Linux AMD64 launcher reuses [dockur/windows](https://github.com/dockur/windows)
to boot Windows 11 under QEMU/KVM. One common Windows disk supplies Python, Git
Bash and Just. CUDA and ROCm tasks use their respective Windows drivers and a
physical PCI GPU. The public image contains recipes and tools, never a Windows
installation, product key, private source or job credentials.

This is a rehearsal implementation, not a qualified image family. Existing
Linux image cohorts and production aliases are unchanged. Windows GPU smoke,
driver installation, repeated GPU resets and scheduler cancellation recovery
must pass on the actual hardware before enabling production work.

## Host contract

The caller must reserve the entire Linux x86_64 host exclusively. KVM and IOMMU
must be enabled. The selected GPU's complete IOMMU group may contain only display
and audio functions; primary boot displays and unrelated devices are rejected.
The host's GPU lifecycle manager must bind that group to `vfio-pci` before `run`,
then restore every original host driver after QEMU stops. This launcher deliberately
does not change PCI bindings, stop the desktop or edit boot configuration.

The scheduler must quarantine the allocation if VM teardown or GPU restoration
fails, and reconcile that state after crashes or lease expiry before admitting
another job. A supplied `--lease` records the caller's reservation; it does not
create or independently verify a reservation. Cancellation stops and removes
the VM before the launcher returns. No host Docker socket or credentials are
shared with Windows. The guest runs the caller's admitted task as SYSTEM.

For topology inspection without detaching a GPU:

```sh
just --justfile windows/justfile doctor --backend cuda --gpu 0000:01:00.0 --inspect
```

`--inspect` establishes topology only. Without that flag, the same command
requires VFIO bindings. Neither mode establishes Windows inference qualification.
The AMD integrated GPU must be tested through repeated detach/reattach cycles;
native Windows support alone does not establish passthrough support.

## Prepare once

Supply an existing Windows 11 x64 ISO and its trusted SHA-256. The launcher never
downloads replacement Windows media. Use a storage filesystem with at least
64 GiB free, plus room for concurrent copies; Btrfs/XFS reflinks reduce copy cost.
Windows media and disks remain operator-controlled artifacts.

```sh
just --justfile windows/justfile image
image=$(docker image inspect --format '{{.Id}}' mesh-windows-smoke:local)
just --justfile windows/justfile prepare \
  --image "$image" --iso /media/windows11.iso --iso-sha256 "$WINDOWS_ISO_SHA256" \
  --work /var/lib/mesh-windows/base-v1
```

Preparation installs checksum-pinned official Python, Git and Just downloads,
registers a startup task, emits a success marker and shuts down. Only successful
preparation writes `base.json`, which records the ISO, tools, launcher and all
storage-file hashes. The disk itself is never published by this repository.

## Rehearse a task

Create a fresh input directory containing `task.ps1`, a signed official Windows
vendor installer as `driver.exe`, and `driver.json`:

```json
{
  "backend": "cuda",
  "device_id": "2c02",
  "sha256": "<SHA-256 of the supplied NVIDIA Windows driver installer>"
}
```

Use `rocm` with the assigned AMD device identity for the HIP profile. Each
disposable guest verifies the driver hash and Authenticode signature, checks the
passed-through GPU identity, installs the driver and reboots once before running
the task. The task must check subprocess exit codes and exit nonzero on failure.
Drivers are supplied explicitly rather than guessed from mutable download links.

With the host GPU already bound to VFIO under an exclusive reservation:

```sh
just --justfile windows/justfile run \
  --image "$image" --base /var/lib/mesh-windows/base-v1 \
  --backend cuda --gpu 0000:01:00.0 --lease "$EXCLUSIVE_RESERVATION_ID" \
  --input /work/admitted-input --work /work/windows-attempt-1 --timeout 3600
```

The launcher verifies the base receipt and makes a disposable storage copy.
The base is never mounted into the running VM. Collect `shared/output` for QEMU
logs, driver discovery, the task transcript, its exit receipt and task-specific
evidence. A missing marker, deadline, failed task or failed teardown fails the run.
The caller may delete the disposable work directory only after collecting evidence
and restoring the GPU. Preserve the golden base and its receipt for reuse.

## Validation

`just --justfile windows/justfile check` exercises device admission, mount scope,
failed-guest cleanup and base tamper detection offline. The repository's existing
test runner includes this suite. These tests do not claim hardware qualification.
