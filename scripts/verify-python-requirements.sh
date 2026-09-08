#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 && -x "$1" && -f "$2" ]] || {
  echo 'usage: verify-python-requirements.sh PIP REQUIREMENTS_FILE' >&2
  exit 2
}
pip_binary="$1"
requirements="$2"
pip_version="$("$pip_binary" --version)"
if [[ ! "$pip_version" =~ ^pip\ ([0-9]+)\.([0-9]+) ]] \
  || (( 10#${BASH_REMATCH[1]} < 22 || (10#${BASH_REMATCH[1]} == 22 && 10#${BASH_REMATCH[2]} < 2) )); then
  echo "Python requirement verification needs pip 22.2 or newer for --report; found: $pip_version" >&2
  exit 1
fi
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
