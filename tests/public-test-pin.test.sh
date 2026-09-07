#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

for dockerfile in Dockerfile Dockerfile.ui; do
  grep -Fxq 'COPY config/playwright-pin.txt /tmp/mesh-runner-expected-playwright.txt' "$repository_root/$dockerfile"
  run_command="$(awk '
    /^FROM public AS public-test$/ { active=1; next }
    active && /^FROM / { exit }
    active && /^RUN / { run=1; sub(/^RUN /, "") }
    active && run { print }
  ' "$repository_root/$dockerfile")"
  run_command="${run_command//\/usr\/local\/bin\/verify-runner-image/verify_fixture}"
  run_command="${run_command//verify-runner-image/verify_fixture}"
  run_command="${run_command//\/__e\/node24\/bin\/node/node}"
  cat > "$temporary_directory/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat() {
  case "$1" in
    /tmp/mesh-runner-expected-playwright.txt) printf '%s\n' "$FIXTURE_PIN" ;;
    /etc/mesh-runner-playwright-version) printf '9.9.9\n' ;;
    *) echo "unexpected file read: $*" >&2; return 1 ;;
  esac
}
verify_fixture() {
  [[ "$#" == 7 && "$1" == public && "$2" == "$BACKEND" && "$7" == "$FIXTURE_EXPECTED" ]]
}
node() { :; }
EOF
  printf '%s\n' "$run_command" >> "$temporary_directory/run.sh"
  if [[ "$dockerfile" == Dockerfile.ui ]]; then
    browser_backend=browser
    ordinary_backend=ui
  else
    browser_backend=web
    ordinary_backend=cpu
  fi
  for pin in 1.62.1 1.63.0; do
    for backend in "$browser_backend" "$ordinary_backend"; do
      expected=none
      if [[ "$backend" == "$browser_backend" ]]; then expected="$pin"; fi
      env BACKEND="$backend" MESH_LLM_REVISION=fixture RUNNER_IMAGES_REVISION=fixture \
        CUDA_SERIES=none ROCM_VERSION=none FIXTURE_PIN="$pin" FIXTURE_EXPECTED="$expected" \
        "$BASH" "$temporary_directory/run.sh"
    done
  done
done
echo "Public test targets verify the independent Playwright pin"
