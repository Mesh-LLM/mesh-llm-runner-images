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

## Cache installation media once per site

Microsoft's consumer ISO download links expire after 24 hours. Generate a fresh
link on the [Microsoft download page](https://www.microsoft.com/software-download/windows11)
and take the SHA-256 for the selected language/architecture from that page's
verification section. The temporary link is a bootstrap input, never a CI pin.
`media.json` records the selected release, language, filename and Microsoft hash;
`cache-iso` defaults to that hash unless `--sha256` explicitly selects other media.

Store the link in a private local file, then admit the ISO into each site's NFS
cache. Downloads follow HTTPS redirects and resume partial transfers. If a link
expires mid-transfer, repeat with a fresh link for the same ISO and checksum.

```sh
iso=$(just --justfile windows/justfile cache-iso \
  --cache "$WINDOWS_NFS_CACHE" --require-nfs \
  --sha256 "$WINDOWS_ISO_SHA256" --url-file /private/windows-iso-url.txt)
```

The helper serializes publishers using an NFS file lock, verifies the complete
download, and atomically publishes `media/sha256/<digest>/windows11.iso` plus a
size/hash receipt. Temporary URLs are not written to receipts or command arguments.
Consumers verify cached bytes and need no URL or network download. A corrupt
cache entry fails instead of downloading replacement media silently.

An already downloaded ISO, or a transferred copy from another site's cache, can
be admitted with `--source /path/to/windows11.iso` instead of `--url-file`.
Both sites use the same trusted digest; their NFS paths are site-local. The
publisher that starts a partial download owns its continuation; completed media
is readable by consumers with different numeric user IDs.

Use a separate NFS directory for immutable prepared bases and a unique attempt
directory for every guest. Never boot a shared writable golden disk. Keep the base on NFS. Each attempt uses a small local QCOW2 overlay, with the
golden data disk mounted read-only. At least 10 GiB free space is required; the
launcher stops if the remaining reserve falls below 2 GiB.
Configure the dedicated cache directories for the export's mapped identities;
sticky directories can prevent cleanup when the server remaps numeric UIDs.
The launcher preserves NFS ownership mapping instead of attempting local-host
UID restoration with `chown` on the server.
The pinned upstream driver extraction is also adjusted to use
`bsdtar --no-same-owner`, so root-owned archive entries do not require NFS chown.
Only the disposable setup-driver tree is made owner-writable before unused
variants are pruned; source archives and the admitted ISO remain unchanged.

## Prepare once

Supply the admitted Windows 11 x64 ISO and its trusted SHA-256. The launcher never
downloads replacement Windows media. Prepare on a local SSD with at least 64 GiB
free, then publish the completed base to NFS.
Windows media and disks remain operator-controlled artifacts.

```sh
just --justfile windows/justfile image
image=$(docker image inspect --format '{{.Id}}' mesh-windows-smoke:local)
just --justfile windows/justfile prepare \
  --image "$image" --iso "$iso" --iso-sha256 "$WINDOWS_ISO_SHA256" \
  --work /var/tmp/windows-base-v1
just --justfile windows/justfile publish --source /var/tmp/windows-base-v1 \
  --target "$WINDOWS_NFS_CACHE/bases/base-v1"
```

Preparation installs checksum-pinned official Python, Git and Just downloads,
registers a startup task, emits a success marker and shuts down. Only successful
preparation writes `base.json`, which records the ISO, tools, launcher and all
storage-file hashes. `publish` compresses the data disk, verifies virtual disk equality and every
cache byte, then atomically publishes storage, its receipt and the exact launcher
archive to NFS. The disk itself is never published by this repository.

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
  --image "$image" --base "$WINDOWS_NFS_CACHE/bases/base-v1" \
  --backend cuda --gpu 0000:01:00.0 --lease "$EXCLUSIVE_RESERVATION_ID" \
  --input /work/admitted-input --work "$WINDOWS_NFS_CACHE/attempts/unique-reservation" --timeout 3600
```

The launcher verifies the base receipt and creates a disposable local QCOW2
overlay. The base storage is mounted read-only at `/base`; mutable EFI state is
copied into the attempt directory. Collect `shared/output` for QEMU
logs, driver discovery, the task transcript, its exit receipt and task-specific
evidence. A missing marker, deadline, failed task or failed teardown fails the run.
The caller may delete the disposable work directory only after collecting evidence
and restoring the GPU. Preserve the golden base and its receipt for reuse.

## Validation

`just --justfile windows/justfile check` exercises device admission, mount scope,
failed-guest cleanup and base tamper detection offline. The repository's existing
test runner includes this suite. These tests do not claim hardware qualification.

## Install host recovery

`host.py` and `install-host.sh` supply the Linux host lifecycle helper. Install
from a reviewed checkout as root, passing an operator-owned JSON configuration
and the exact launcher image ID used to prepare the base:

```sh
bash windows/install-host.sh /private/host.json "$image"
```

The JSON contains `backend`, the approved `gpu` PCI address, enrolled `job_user`
and numeric `job_uid`, `job_home`, `jy_binary`, `jy_config`, and
`github_busy_marker`. Keep this host-specific configuration outside Git. The
installer creates `/usr/local/bin/mesh-windows-host` and a root systemd recovery
timer. The wrapper uses the host's existing Docker administration capability;
Windows guests still receive only explicit KVM/VFIO devices.

Acquisition verifies the connected single-slot scheduler and the current native
reservation or accepted GitHub worker, journals original bindings, then persists
`jy off` before stopping display services and assigning VFIO. A 2-hour lease and
owner PID/start-time/boot identity let the independent timer recover abandoned
allocations. Recovery stops only containers labeled for that lease, restores
bindings and display services, and verifies native GPU discovery before `jy on`.
Intervening operator configuration changes or restoration failures preserve
quarantine. The root journal survives job cancellation and reboot. Physical
passthrough, reset and recovery still require qualification on each host type.

The base pins a small startup bootstrap. Each job supplies checksum-admitted
`RunTask.ps1` and `InstallDriver.ps1` from the pinned recipe checkout, so a guest
script fix does not require rebuilding Windows. Changing the bootstrap requires
a fresh base; incompatible bases fail before boot. PCI detection uses PnP
entities before vendor installation and requires successful device initialization
after the driver's reboot.

For hosts with limited local space, configure the attempt directory on NFS.
Windows vendor installation can create substantially more writes than the final
installed driver occupies; the disk reserve remains enforced on either filesystem.
