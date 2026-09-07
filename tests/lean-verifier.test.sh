#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
export FIXTURE_ROOT="$temporary_directory/root"
export FIXTURE_LOG="$temporary_directory/commands.jsonl"
mkdir -p "$FIXTURE_ROOT/etc" "$FIXTURE_ROOT/home/runner/externals/node24/bin" \
  "$FIXTURE_ROOT/home/runner/.local/share/pnpm/store" "$FIXTURE_ROOT/__e/node24/bin" \
  "$FIXTURE_ROOT/opt/mesh-llm/manifests" "$FIXTURE_ROOT/opt/ms-playwright/chromium-1234" \
  "$temporary_directory/bin"
printf 'public\n' > "$FIXTURE_ROOT/etc/mesh-runner-environment"
printf 'ui\n' > "$FIXTURE_ROOT/etc/mesh-runner-backend"
printf '%040d\n' 1 > "$FIXTURE_ROOT/etc/mesh-llm-revision"
printf '%040d\n' 2 > "$FIXTURE_ROOT/etc/mesh-runner-images-revision"
printf 'none\n' > "$FIXTURE_ROOT/etc/mesh-runner-cuda-series"
printf 'none\n' > "$FIXTURE_ROOT/etc/mesh-runner-rocm-version"
printf '24\n' > "$FIXTURE_ROOT/etc/mesh-runner-node-major"
printf '10.34.5\n' > "$FIXTURE_ROOT/etc/mesh-runner-pnpm-version"
printf '{}\n' > "$FIXTURE_ROOT/opt/mesh-llm/manifests/manifest-index.json"
printf '%040d\n' 1 > "$FIXTURE_ROOT/opt/mesh-llm/manifests/source-revision.txt"
touch "$FIXTURE_ROOT/home/runner/externals/node24/bin/node" "$FIXTURE_ROOT/__e/node24/bin/node"
chmod +x "$FIXTURE_ROOT/home/runner/externals/node24/bin/node" "$FIXTURE_ROOT/__e/node24/bin/node"

# Relocate filesystem checks into a fixture; execute the actual verifier logic.
python3 - "$repository_root/scripts/verify-runner-image.sh" "$temporary_directory/verifier.sh" "$FIXTURE_ROOT" <<'PY'
import sys
from pathlib import Path
source, output, root = sys.argv[1:]
text = Path(source).read_text()
for prefix in ("/etc/mesh", "/opt/", "/home/runner", "/__e/"):
    text = text.replace(prefix, root + prefix)
Path(output).write_text(text)
PY

cat > "$temporary_directory/fixture-env.sh" <<'ENV'
command() {
  if [[ "$1" == -v ]]; then
    printf 'required:%s\n' "$2" >> "$FIXTURE_LOG"
    if [[ "$2" == "${FIXTURE_MISSING_COMMAND:-}" ]]; then return 1; fi
    case "$2" in
      cargo|rustc|sccache) [[ "${FIXTURE_FULL:-false}" == true ]] || return 1 ;;
    esac
    printf '%s\n' "$2"
    return 0
  fi
  builtin command "$@"
}
uname() { printf '%s\n' "${FIXTURE_ARCH:-x86_64}"; }
id() { if [[ "$1" == -u ]]; then echo 0; else echo runner; fi; }
docker() { echo 'Docker version fixture'; }
cargo() { echo 'cargo fixture'; }
pnpm() { printf '%s\n' "${FIXTURE_PNPM_VERSION:-10.34.5}"; }
node() {
  printf 'node:%s\n' "$*" >> "$FIXTURE_LOG"
  case "$1" in
    --version) printf '%s\n' "${FIXTURE_NODE_VERSION:-v24.18.0}" ;;
    -p) printf '%s\n' "${FIXTURE_PLAYWRIGHT_VERSION:-1.62.1}" ;;
    -e) return "${FIXTURE_BROWSER_EXIT:-0}" ;;
    *) return 1 ;;
  esac
}
python() {
  if [[ "$1" == --version ]]; then echo 'Python 3 fixture';
  else cat >> "$FIXTURE_LOG"; fi
}
ENV
export BASH_ENV="$temporary_directory/fixture-env.sh"
export ONNXRUNTIME_NODE_INSTALL=skip
export npm_config_store_dir="$FIXTURE_ROOT/home/runner/.local/share/pnpm/store"
unset CARGO_HOME RUSTUP_HOME VIRTUAL_ENV PLAYWRIGHT_BROWSERS_PATH PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD

verify() { bash "$temporary_directory/verifier.sh" "$@"; }
expect_failure() {
  if "$@" > "$temporary_directory/failure" 2>&1; then
    echo "expected verifier to reject fixture: $*" >&2
    exit 1
  fi
}
mesh_revision="$(printf '%040d' 1)"
runner_revision="$(printf '%040d' 2)"
verify public ui "$mesh_revision" none none "$runner_revision" none > "$temporary_directory/ui-output"
grep -q '"cargo": null' "$temporary_directory/ui-output"
if grep -Eq '^required:(cmake|lld|ninja|python)$|import langchain_openai' "$FIXTURE_LOG"; then
  echo 'lean verifier requested full-image tools or AI dependencies' >&2; exit 1
fi
expect_failure env FIXTURE_ARCH=aarch64 bash "$temporary_directory/verifier.sh" public ui
expect_failure env FIXTURE_MISSING_COMMAND=tar bash "$temporary_directory/verifier.sh" public ui
expect_failure env FIXTURE_MISSING_COMMAND=just bash "$temporary_directory/verifier.sh" public ui
expect_failure env FIXTURE_NODE_VERSION=v22.1.0 bash "$temporary_directory/verifier.sh" public ui
expect_failure env FIXTURE_PNPM_VERSION=10.34.4 bash "$temporary_directory/verifier.sh" public ui
expect_failure env ONNXRUNTIME_NODE_INSTALL= bash "$temporary_directory/verifier.sh" public ui
expect_failure env VIRTUAL_ENV=/unexpected/venv bash "$temporary_directory/verifier.sh" public ui
mkdir "$FIXTURE_ROOT/opt/mesh-llm/venv"
expect_failure verify public ui
rmdir "$FIXTURE_ROOT/opt/mesh-llm/venv"
expect_failure env FIXTURE_FULL=true bash "$temporary_directory/verifier.sh" public ui
expect_failure verify public ui "$runner_revision" none none "$runner_revision" none
expect_failure verify public ui "$mesh_revision" 12-9 none "$runner_revision" none
expect_failure verify public ui "$mesh_revision" none 7.0 "$runner_revision" none
expect_failure verify public ui "$mesh_revision" none none "$mesh_revision" none
printf 'self-hosted\n' > "$FIXTURE_ROOT/etc/mesh-runner-environment"
expect_failure verify self-hosted ui
printf 'public\n' > "$FIXTURE_ROOT/etc/mesh-runner-environment"

printf 'browser\n' > "$FIXTURE_ROOT/etc/mesh-runner-backend"
printf '1.62.1\n' > "$FIXTURE_ROOT/etc/mesh-runner-playwright-version"
printf 'chromium-1234\n' > "$FIXTURE_ROOT/etc/mesh-runner-chromium-build"
export PLAYWRIGHT_BROWSERS_PATH="$FIXTURE_ROOT/opt/ms-playwright"
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
verify public browser "$mesh_revision" none none "$runner_revision" 1.62.1 >/dev/null
grep -q 'chromium.launch' "$FIXTURE_LOG"
expect_failure verify public browser "$mesh_revision" none none "$runner_revision" 1.61.0
expect_failure env FIXTURE_PLAYWRIGHT_VERSION=1.61.0 bash "$temporary_directory/verifier.sh" public browser
expect_failure env FIXTURE_BROWSER_EXIT=7 bash "$temporary_directory/verifier.sh" public browser
expect_failure env PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=0 bash "$temporary_directory/verifier.sh" public browser
printf 'missing-chromium\n' > "$FIXTURE_ROOT/etc/mesh-runner-chromium-build"
expect_failure verify public browser

# Existing full CPU requirements and AI imports remain mandatory.
printf 'cpu\n' > "$FIXTURE_ROOT/etc/mesh-runner-backend"
rm "$FIXTURE_ROOT/etc/mesh-runner-playwright-version"
unset PLAYWRIGHT_BROWSERS_PATH PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD ONNXRUNTIME_NODE_INSTALL
export FIXTURE_FULL=true
: > "$FIXTURE_LOG"
verify public cpu "$mesh_revision" none none "$runner_revision" none > "$temporary_directory/cpu-output"
grep -q '"cargo": "cargo fixture"' "$temporary_directory/cpu-output"
for full_command in cargo cmake docker git jq just lld node ninja npm pnpm python rustc sccache; do
  grep -qx "required:$full_command" "$FIXTURE_LOG"
done
grep -q '^import langchain_openai' "$FIXTURE_LOG"
expect_failure env FIXTURE_MISSING_COMMAND=cargo bash "$temporary_directory/verifier.sh" public cpu
printf 'web\n' > "$FIXTURE_ROOT/etc/mesh-runner-backend"
printf '1.62.1\n' > "$FIXTURE_ROOT/etc/mesh-runner-playwright-version"
export PLAYWRIGHT_BROWSERS_PATH="$FIXTURE_ROOT/opt/ms-playwright"
: > "$FIXTURE_LOG"
verify public web "$mesh_revision" none none "$runner_revision" 1.62.1 >/dev/null
grep -q 'chromium.launch' "$FIXTURE_LOG"
grep -q '^import langchain_openai' "$FIXTURE_LOG"
expect_failure env FIXTURE_BROWSER_EXIT=7 bash "$temporary_directory/verifier.sh" public web
echo 'Lean verifier capability, provenance, browser, and full-image regression checks passed'
