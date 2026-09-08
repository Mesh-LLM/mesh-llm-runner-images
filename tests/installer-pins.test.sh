#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
mkdir -p "$temporary_directory/bin" "$temporary_directory/cache"
cp "$repository_root/scripts/install-tools-common.sh" "$temporary_directory/install-tools-common.sh"

# Load installer functions without the real installation entrypoint.
awk '/^cd \/tmp$/ { found=1; exit } { print } END { if (!found) exit 1 }' "$repository_root/scripts/install-core-tools.sh" \
  > "$temporary_directory/functions.sh"
cat > "$temporary_directory/fixture.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$FIXTURE_DIRECTORY/functions.sh"

test() {
  # The base-image contract is covered by real image verification. This
  # fixture must never need or change the host's /home/runner directory.
  [[ "$*" == '-x /home/runner/externals/node24/bin/node' ]] || builtin test "$@"
}
ln() { printf 'ln %s\n' "$*" >> "$FIXTURE_LOG"; }
npm() {
  printf 'npm %s\n' "$*" >> "$FIXTURE_LOG"
  return "${FIXTURE_NPM_EXIT:-0}"
}
pnpm() {
  printf '%s\n' "${FIXTURE_PNPM_OUTPUT:-10.34.5}"
  return "${FIXTURE_PNPM_EXIT:-0}"
}
runuser() {
  [[ "$1 $2 $3 $4" == '-u runner -- env' ]]
  shift 4
  while [[ "$1" == *=* ]]; do shift; done
  case "$1" in
    bash) "$@" ;;
    /home/runner/.cargo/bin/rustup)
      printf 'rustup %s\n' "${*:2}" >> "$FIXTURE_LOG"
      return "${FIXTURE_RUSTUP_EXIT:-0}"
      ;;
    /home/runner/.cargo/bin/rustc)
      printf '%s\n' "${FIXTURE_RUST_OUTPUT:-rustc 1.98.1 (fixture 2026-08-20)}"
      return "${FIXTURE_RUST_EXIT:-0}"
      ;;
    *) echo "unexpected runner command: $*" >&2; return 1 ;;
  esac
}
case "$FIXTURE_ACTION" in
  validate) validate_tool_pins ;;
  node) validate_tool_pins; wire_node_from_base ;;
  rust) validate_tool_pins; install_rust ;;
esac
EOF
cat > "$temporary_directory/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$FIXTURE_LOG"
if [[ "${FIXTURE_CURL_FAIL:-0}" == 1 ]]; then exit 22; fi
printf '# fixture bootstrap\n'
EOF
cat > "$temporary_directory/bin/sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'bootstrap %s\n' "$*" >> "$FIXTURE_LOG"
cat >/dev/null
exit "${FIXTURE_BOOTSTRAP_EXIT:-0}"
EOF
chmod +x "$temporary_directory/bin/curl" "$temporary_directory/bin/sh"

run_fixture() {
  local action="$1" name="$2"
  shift 2
  env PATH="$temporary_directory/bin:$(dirname "$BASH"):$PATH" \
    TARGETARCH=amd64 NODE_MAJOR=24 PNPM_VERSION=10.34.5 RUST_VERSION=1.98.1 \
    JUST_VERSION=1.57.0 SCCACHE_VERSION=0.16.0 OPENAI_NPM_VERSION=7.5.0 \
    DOWNLOAD_CACHE_DIR="$temporary_directory/cache" FIXTURE_DIRECTORY="$temporary_directory" \
    FIXTURE_ACTION="$action" FIXTURE_LOG="$temporary_directory/$name.log" \
    "$@" "$BASH" "$temporary_directory/fixture.sh"
}

expect_failure() {
  if "$@" >"$temporary_directory/failure.log" 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

run_fixture node node
grep -Fxq 'npm install --global pnpm@10.34.5' "$temporary_directory/node.log"
grep -Fxq 'npm install --global openai@7.5.0' "$temporary_directory/node.log"
run_fixture rust rust
grep -Fxq 'curl --proto =https --tlsv1.2 -fsSL https://sh.rustup.rs' "$temporary_directory/rust.log"
grep -Fxq 'bootstrap -s -- -y --profile minimal --default-toolchain 1.98.1' "$temporary_directory/rust.log"
grep -Fxq 'rustup component add --toolchain 1.98.1 clippy rustfmt' "$temporary_directory/rust.log"
grep -Fxq 'rustup target add --toolchain 1.98.1 aarch64-linux-android' "$temporary_directory/rust.log"
run_fixture node node-override PNPM_VERSION=11.2.3 FIXTURE_PNPM_OUTPUT=11.2.3
grep -Fxq 'npm install --global pnpm@11.2.3' "$temporary_directory/node-override.log"
run_fixture rust rust-override RUST_VERSION=1.99.2 'FIXTURE_RUST_OUTPUT=rustc 1.99.2 (fixture)'
grep -Fxq 'bootstrap -s -- -y --profile minimal --default-toolchain 1.99.2' \
  "$temporary_directory/rust-override.log"
grep -Fxq 'rustup component add --toolchain 1.99.2 clippy rustfmt' "$temporary_directory/rust-override.log"
grep -Fxq 'rustup target add --toolchain 1.99.2 aarch64-linux-android' "$temporary_directory/rust-override.log"

# Pins are required, canonical numeric release versions, never tags or ranges.
for pin in PNPM_VERSION RUST_VERSION JUST_VERSION SCCACHE_VERSION OPENAI_NPM_VERSION; do
  expect_failure run_fixture validate missing "$pin="
  expect_failure run_fixture validate floating "$pin=latest"
done
for malformed in stable 10 10.34 '^10.34.5' '10.34.5-beta.1' '01.34.5' '10.34.5; echo unsafe'; do
  expect_failure run_fixture validate malformed "PNPM_VERSION=$malformed"
  expect_failure run_fixture validate malformed "RUST_VERSION=$malformed"
done

# Check the installed executable instead of trusting a successful install.
expect_failure run_fixture node wrong-pnpm FIXTURE_PNPM_OUTPUT=10.34.4
expect_failure run_fixture node failed-pnpm FIXTURE_PNPM_EXIT=27
expect_failure run_fixture node failed-npm FIXTURE_NPM_EXIT=28
expect_failure run_fixture rust wrong-rust 'FIXTURE_RUST_OUTPUT=rustc 1.98.0 (fixture)'
expect_failure run_fixture rust malformed-rust 'FIXTURE_RUST_OUTPUT=compiler 1.98.1'
expect_failure run_fixture rust failed-rust FIXTURE_RUST_EXIT=29
expect_failure run_fixture rust failed-rustup FIXTURE_RUSTUP_EXIT=30
expect_failure run_fixture rust failed-bootstrap FIXTURE_BOOTSTRAP_EXIT=31

# A failed download followed by a successful empty bootstrap must still fail.
expect_failure run_fixture rust failed-curl FIXTURE_CURL_FAIL=1
if grep -q '^rustup ' "$temporary_directory/failed-curl.log"; then
  echo "Rust installation continued after the bootstrap download failed" >&2
  exit 1
fi

echo "Exact installer pin and failure propagation tests passed"
