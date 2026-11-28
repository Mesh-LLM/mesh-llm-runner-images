# syntax=docker/dockerfile:1.19
# Windows runs under KVM inside this Linux image. Windows media and disks are
# supplied by the operator and never become public container layers.
FROM docker.io/dockurr/windows@sha256:59f8bed19cfd49cf1701debe34f9df6311e61a4e2ae68aa9f41206e2184e31cc
# Driver payloads are unpacked into the operator's storage filesystem. NFS
# remaps root, so retain the extracting account instead of archive UID/GID 0.
# Fail the build if the pinned upstream extraction point changes.
RUN python3 - <<'PY'
from pathlib import Path
script = Path('/run/install.sh')
source = script.read_text()
before = 'bsdtar -xf /var/drivers.txz'
assert source.count(before) == 1, 'upstream driver extraction changed'
source = source.replace(before, 'bsdtar --no-same-owner -xf /var/drivers.txz')
selection = '  selectDrivers "$version" "$drivers" "$target" || return 1'
assert source.count(selection) == 1, 'upstream driver selection changed'
# Some archive directories are read-only. Squashed NFS root cannot rely on
# CAP_DAC_OVERRIDE when pruning unused driver variants on the server.
source = source.replace(selection, '  chmod -R u+rwX "$drivers" || return 1\n' + selection)
script.write_text(source)
PY
COPY guest/ /opt/mesh-windows/guest/
COPY tools.json /opt/mesh-windows/tools.json
