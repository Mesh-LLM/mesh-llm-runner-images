#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
python3 -m venv "$temporary/venv"
pip_binary="$temporary/venv/bin/pip"
verifier="$repository_root/scripts/verify-python-requirements.sh"
requirements="$temporary/requirements.txt"

# Tiny real wheels exercise pip's resolver without network or external tools.
python3 - "$temporary" <<'PY'
import sys
import zipfile
from pathlib import Path

for version in ('1.0.0', '2.0.0'):
    name = 'mesh_lock_fixture'
    directory = f'{name}-{version}.dist-info'
    with zipfile.ZipFile(Path(sys.argv[1]) / f'{name}-{version}-py3-none-any.whl', 'w') as wheel:
        wheel.writestr(f'{name}/__init__.py', f'__version__ = "{version}"\n')
        wheel.writestr(f'{directory}/METADATA',
                       f'Metadata-Version: 2.1\nName: mesh-lock-fixture\nVersion: {version}\n')
        wheel.writestr(f'{directory}/WHEEL',
                       'Wheel-Version: 1.0\nGenerator: fixture\nRoot-Is-Purelib: true\nTag: py3-none-any\n')
        wheel.writestr(f'{directory}/RECORD', '')
PY
"$pip_binary" install --disable-pip-version-check --no-index --no-deps \
  "$temporary/mesh_lock_fixture-1.0.0-py3-none-any.whl" >/dev/null
printf 'mesh-lock-fixture>=1.0.0,<2\n' > "$requirements"
"$BASH" "$verifier" "$pip_binary" "$requirements" >/dev/null

expect_rejected() {
  if "$BASH" "$verifier" "$pip_binary" "$requirements" > "$temporary/failure.log" 2>&1; then
    echo 'expected incompatible Python requirements to fail' >&2
    exit 1
  fi
  grep -Fq 'refresh config/python-requirements.lock' "$temporary/failure.log"
  [[ "$("$temporary/venv/bin/python" -c 'import mesh_lock_fixture; print(mesh_lock_fixture.__version__)')" == 1.0.0 ]]
}

printf 'mesh-missing-fixture==1.0.0\n' > "$requirements"
expect_rejected
printf 'mesh-lock-fixture==2.0.0\n' > "$requirements"
expect_rejected
# pip can resolve this wheel offline, but installing it would change the lock.
printf '%s\n' "$temporary/mesh_lock_fixture-2.0.0-py3-none-any.whl" > "$requirements"
expect_rejected
printf '%s\n' "--find-links $temporary" 'mesh-lock-fixture==2.0.0' > "$requirements"
expect_rejected
echo 'Frozen Python requirements compatibility checks passed'
