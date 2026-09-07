#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
printf '1.62.1\n' > "$temporary_directory/pin.txt"
cat > "$temporary_directory/fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Load the real functions, but replace all installation/ownership operations.
# shellcheck source=/dev/null
source "$REPOSITORY_ROOT/scripts/install-ui-tools.sh"
# shellcheck source=/dev/null
source "$REPOSITORY_ROOT/scripts/install-playwright.sh"
test() { [[ "$*" == '-x /home/runner/externals/node24/bin/node' ]] || builtin test "$@"; }
ln() { printf 'ln %s\n' "$*" >> "$FIXTURE_LOG"; }
npm() { printf 'npm %s\n' "$*" >> "$FIXTURE_LOG"; return "${FIXTURE_NPM_EXIT:-0}"; }
pnpm() { printf '%s\n' "${FIXTURE_PNPM_OUTPUT:-10.34.5}"; }
node() { printf '%s\n' "${FIXTURE_NODE_OUTPUT:-v24.18.0}"; }
just() { printf 'just 1.57.0\n'; }
install_just() { printf 'install_just %s\n' "$JUST_VERSION" >> "$FIXTURE_LOG"; }
chown() { printf 'chown %s\n' "$*" >> "$FIXTURE_LOG"; }
playwright() {
  if [[ "$*" == --version ]]; then
    printf '%s\n' "${FIXTURE_PLAYWRIGHT_OUTPUT:-Version 1.62.1}"
    return
  fi
  [[ "${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD-unset}" == '' ]]
  printf 'playwright %s\n' "$*" >> "$FIXTURE_LOG"
  case "$*" in
    'install-deps chromium') return "${FIXTURE_DEPS_EXIT:-0}" ;;
    'install chromium')
      if [[ "${FIXTURE_NO_BROWSER:-0}" != 1 ]]; then mkdir -p "$PLAYWRIGHT_BROWSERS_PATH/chromium-fixture"; fi
      return "${FIXTURE_BROWSER_EXIT:-0}"
      ;;
    *) echo "unexpected playwright invocation: $*" >&2; return 1 ;;
  esac
}
case "$FIXTURE_ACTION" in
  ui) install_ui_tools ;;
  browser) install_playwright "$PIN_FILE" "$METADATA_ROOT" ;;
esac
EOF

run_fixture() {
  local action="$1" name="$2"
  shift 2
  env REPOSITORY_ROOT="$repository_root" FIXTURE_ACTION="$action" \
    FIXTURE_LOG="$temporary_directory/$name.log" \
    DOWNLOAD_CACHE_DIR="$temporary_directory/cache" \
    TARGETARCH=amd64 NODE_MAJOR=24 PNPM_VERSION=10.34.5 JUST_VERSION=1.57.0 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 PLAYWRIGHT_BROWSERS_PATH="$temporary_directory/$name-browser" \
    PIN_FILE="$temporary_directory/pin.txt" METADATA_ROOT="$temporary_directory/$name-metadata" \
    "$@" "$BASH" "$temporary_directory/fixture.sh"
}
expect_failure() {
  if "$@" > "$temporary_directory/failure.log" 2>&1; then
    echo "expected lean installer failure: $*" >&2
    exit 1
  fi
}

run_fixture ui ui
grep -Fxq 'npm install --global pnpm@10.34.5' "$temporary_directory/ui.log"
grep -Fxq 'install_just 1.57.0' "$temporary_directory/ui.log"
if grep -Eq 'openai|rust|cargo|sccache' "$temporary_directory/ui.log"; then
  echo "lean installer invoked full-image tooling" >&2
  exit 1
fi
expect_failure run_fixture ui wrong-node FIXTURE_NODE_OUTPUT=v25.0.0
expect_failure run_fixture ui arm64 TARGETARCH=arm64
expect_failure run_fixture ui unpinned PNPM_VERSION=latest
expect_failure run_fixture ui wrong-pnpm FIXTURE_PNPM_OUTPUT=10.34.4
expect_failure run_fixture ui npm-failed FIXTURE_NPM_EXIT=22

run_fixture browser browser
grep -Fxq 'npm install --global playwright@1.62.1' "$temporary_directory/browser.log"
grep -Fxq 'playwright install-deps chromium' "$temporary_directory/browser.log"
grep -Fxq 'playwright install chromium' "$temporary_directory/browser.log"
grep -Fxq '1.62.1' "$temporary_directory/browser-metadata/mesh-runner-playwright-version"
grep -Fxq 'chromium-fixture' "$temporary_directory/browser-metadata/mesh-runner-chromium-build"
expect_failure run_fixture browser wrong-browser FIXTURE_PLAYWRIGHT_OUTPUT='Version 1.62.0'
test ! -e "$temporary_directory/wrong-browser-metadata"
expect_failure run_fixture browser no-browser FIXTURE_NO_BROWSER=1
expect_failure run_fixture browser deps-failed FIXTURE_DEPS_EXIT=23
expect_failure run_fixture browser download-failed FIXTURE_BROWSER_EXIT=24
printf 'latest\n' > "$temporary_directory/pin.txt"
expect_failure run_fixture browser unpinned-browser
test ! -e "$temporary_directory/unpinned-browser.log"
echo "Lean installer pin and browser lifecycle tests passed"
