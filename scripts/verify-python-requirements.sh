#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 && -x "$1" && -f "$2" ]] || {
  echo 'usage: verify-python-requirements.sh PIP REQUIREMENTS_FILE' >&2
  exit 2
}
pip_binary="$1"
requirements="$2"
report="$(mktemp)"
trap 'rm -f "$report"' EXIT

# A successful resolver exit is insufficient: a local wheel can still propose
# changing the environment. The installed, reviewed closure must suffice.
if ! "$pip_binary" install --disable-pip-version-check \
    --dry-run --no-index --report "$report" -r "$requirements" \
  || ! jq -e '.install == []' "$report" >/dev/null; then
  echo 'MeshLLM Python requirements are not satisfied by the frozen runtime; refresh config/python-requirements.lock (see docs/PYTHON_DEPENDENCIES.md)' >&2
  exit 1
fi
