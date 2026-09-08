#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

for dockerfile in Dockerfile Dockerfile.ui; do
  grep -Fxq 'COPY config/playwright-pin.txt config/tool-pins.json config/cache-policy.json config/python-requirements.lock /opt/mesh-runner-verification/' "$repository_root/$dockerfile"
  run_command="$(awk '
    /^FROM public AS public-test$/ { active=1; next }
    active && /^FROM / { exit }
    active && /^RUN / { run=1; sub(/^RUN --network=none /, "") }
    active && run { print }
  ' "$repository_root/$dockerfile")"
  run_command="${run_command//bash \/opt\/mesh-runner-verification\/verify-runner-candidate.sh/verify_fixture}"
  run_command="${run_command//\/tmp\/mesh-runner-identity.json/$temporary_directory\/identity.json}"
  cat > "$temporary_directory/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat() {
  case "$1" in
    /opt/mesh-runner-verification/playwright-pin.txt) printf '%s\n' "$FIXTURE_PIN" ;;
    /etc/mesh-runner-playwright-version) printf '9.9.9\n' ;;
    "$FIXTURE_REPORT") command cat "$1" ;;
    *) echo "unexpected file read: $*" >&2; return 1 ;;
  esac
}
verify_fixture() {
  [[ "$1" == --expected-directory && "$2" == /opt/mesh-runner-verification &&
     "$3" == --verifier-revision && "$4" == "$VERIFIER_REVISION" ]]
  shift 4
  [[ "$#" == 7 && "$1" == public && "$2" == "$BACKEND" && "$7" == "$FIXTURE_EXPECTED" ]]
}
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
      env BACKEND="$backend" MESH_LLM_REVISION=fixture RUNNER_IMAGES_REVISION=fixture VERIFIER_REVISION=separate-fixture \
        CUDA_SERIES=none ROCM_VERSION=none FIXTURE_PIN="$pin" FIXTURE_EXPECTED="$expected" FIXTURE_REPORT="$temporary_directory/identity.json" \
        "$BASH" "$temporary_directory/run.sh"
    done
  done
done
echo "Public test targets verify the independent Playwright pin"
