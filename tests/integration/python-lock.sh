#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 1 && "$1" != -* ]] || {
  echo 'usage: python-lock.sh LOCAL_IMAGE' >&2
  exit 2
}
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
lock_sha="$(python3 - "$repository_root/config/python-requirements.lock" <<'PY'
import hashlib
import pathlib
import sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
docker run --rm --interactive --pull never --network none \
  --env EXPECTED_LOCK_SHA256="$lock_sha" \
  --entrypoint /opt/mesh-llm/venv/bin/python "$1" - <<'PY'
import hashlib
import importlib.metadata
import os
import pathlib
import platform
import re
import subprocess
import sys

lock = pathlib.Path('/etc/mesh-runner-python-requirements.lock').read_bytes()
assert hashlib.sha256(lock).hexdigest() == os.environ['EXPECTED_LOCK_SHA256'], 'image lock differs from source'

def normalize(name):
    return re.sub(r'[-_.]+', '-', name).lower()

expected = {}
for line in lock.decode().splitlines():
    if not line.strip() or line.startswith('#'):
        continue
    match = re.fullmatch(r'([A-Za-z0-9][A-Za-z0-9_.-]*)==([A-Za-z0-9][A-Za-z0-9._+!-]*)', line)
    assert match is not None, f'lock must contain exact package pins: {line}'
    name, version = match.groups()
    key = normalize(name)
    assert key not in expected, f'duplicate lock entry: {name}'
    expected[key] = version
installed = {}
for distribution in importlib.metadata.distributions():
    key = normalize(distribution.metadata['Name'])
    if key == 'pip':
        continue  # Bootstrap tool, deliberately outside the runtime lock.
    assert key not in installed, f'duplicate installed distribution: {key}'
    installed[key] = distribution.version
assert installed == expected, f'runtime differs from lock: expected={expected}, installed={installed}'
subprocess.run([sys.executable, '-m', 'pip', 'check'], check=True)
print(f'{platform.machine()}: all {len(expected)} frozen Python packages match the source lock')
PY
