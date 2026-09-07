#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
mkdir -p "$temporary_directory/bin" "$temporary_directory/repo"
cp -R "$repository_root/scripts" "$repository_root/config" "$temporary_directory/repo/"
verifier="$temporary_directory/repo/scripts/verify-end-to-end.sh"
export MOCK_DOCKER_LOG="$temporary_directory/docker.jsonl"
export PATH="$temporary_directory/bin:$PATH"

cat > "$temporary_directory/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$MOCK_DOCKER_LOG"
if [[ "$1" == buildx && "$2" == imagetools && "$3" == inspect ]]; then
  jq -cn --arg architectures "${MOCK_ARCHITECTURES:-amd64,arm64}" \
    '{manifests: [$architectures | split(",")[] | {platform: {os: "linux", architecture: .}}]}'
elif [[ "$1" == run ]]; then
  if [[ "$*" == *public-web-latest* ]]; then
    exit "${MOCK_WEB_EXIT:-0}"
  fi
else
  exit 64
fi
MOCK
chmod +x "$temporary_directory/bin/docker"

bash "$verifier" --all-backends > "$temporary_directory/output"
jq -se 'any(.[]; .[0] == "run" and (.[6] | contains("public-web-latest")))' \
  "$MOCK_DOCKER_LOG" >/dev/null
jq -se '
  ([.[] | select(.[0] == "run")] | length) == 25
  and ([.[] | select(.[0] == "buildx")] | length) == 15
  and all(.[] | select(.[0] == "run"); length == 14)
  and any(.[]; .[0] == "run" and (.[6] | contains("self-hosted-latest")))
' "$MOCK_DOCKER_LOG" >/dev/null

assert_backend() {
  local tag="$1" platform="$2" environment="$3" backend="$4"
  local cuda="$5" rocm="$6" playwright="$7"
  jq -se --arg image "ghcr.io/mesh-llm/mesh-llm-cuda-runner:$tag" \
    --arg platform "linux/$platform" --arg environment "$environment" \
    --arg backend "$backend" --arg cuda "$cuda" --arg rocm "$rocm" \
    --arg playwright "$playwright" '
      any(.[]; .[0] == "run" and .[3] == $platform and .[6] == $image
        and .[7:] == [$environment, $backend, "", $cuda, $rocm, "", $playwright])
    ' "$MOCK_DOCKER_LOG" >/dev/null
}
assert_backend public-web-latest amd64 public web none none "$(cat "$repository_root/config/playwright-pin.txt")"
assert_backend public-cuda13-latest arm64 public cuda 13-1 none none
assert_backend public-rocm70-latest amd64 public rocm none 7.0 none
assert_backend self-hosted-rocm72-latest amd64 self-hosted rocm none 7.2.3 none
assert_backend self-hosted-latest amd64 self-hosted cuda 12-9 none none
assert_backend self-hosted-latest arm64 self-hosted cpu none none none

# Compare the complete platform set, independently of the matrix generator.
expected_rows="$temporary_directory/expected.tsv"
for environment in public self-hosted; do
  for backend in cpu vulkan cuda12 cuda13; do
    for architecture in amd64 arm64; do
      printf '%s-%s-latest\tlinux/%s\n' "$environment" "$backend" "$architecture"
    done
  done
  for backend in rocm70 rocm72; do
    printf '%s-%s-latest\tlinux/amd64\n' "$environment" "$backend"
  done
done > "$expected_rows"
printf 'public-web-latest\tlinux/amd64\n' >> "$expected_rows"
for tag in public self-hosted; do
  for architecture in amd64 arm64; do
    printf '%s-latest\tlinux/%s\n' "$tag" "$architecture"
  done
done >> "$expected_rows"
jq -sr '.[] | select(.[0] == "run") | [(.[6] | split(":")[-1]), .[3]] | @tsv' \
  "$MOCK_DOCKER_LOG" | sort > "$temporary_directory/actual.tsv"
sort "$expected_rows" > "$temporary_directory/expected-sorted.tsv"
diff -u "$temporary_directory/expected-sorted.tsv" "$temporary_directory/actual.tsv"

: > "$MOCK_DOCKER_LOG"
PUBLIC_TAG=public-custom SELF_HOSTED_TAG=self-hosted-custom bash "$verifier" >/dev/null
jq -se '
  ([.[] | select(.[0] == "run")] | length) == 4
  and ([.[] | select(.[0] == "buildx")] | length) == 2
  and all(.[] | select(.[0] == "run"); .[6] | endswith("-custom"))
' "$MOCK_DOCKER_LOG" >/dev/null

expect_failure() {
  if "$@" > "$temporary_directory/failure" 2>&1; then
    echo "expected verification failure: $*" >&2
    exit 1
  fi
  if grep -Fq 'runner image verification passed' "$temporary_directory/failure"; then
    echo "failed verification reported success" >&2
    exit 1
  fi
}
expect_failure env MOCK_WEB_EXIT=7 bash "$verifier" --all-backends
expect_failure env MOCK_ARCHITECTURES=amd64 bash "$verifier" --all-backends
: > "$MOCK_DOCKER_LOG"
expect_failure bash "$verifier" --unknown
test ! -s "$MOCK_DOCKER_LOG"

# Version expectations must follow the catalog, not a second hardcoded list.
catalog="$temporary_directory/repo/config/runner-image-families.json"
jq '(.backends[] | select(.id == "cuda12") | .cuda_series) = "12-8"' \
  "$catalog" > "$temporary_directory/catalog.json"
cp "$temporary_directory/catalog.json" "$catalog"
printf '1.60.0\n' > "$temporary_directory/repo/config/playwright-pin.txt"
: > "$MOCK_DOCKER_LOG"
bash "$verifier" --all-backends >/dev/null
assert_backend public-web-latest amd64 public web none none 1.60.0
assert_backend self-hosted-latest amd64 self-hosted cuda 12-8 none none

: > "$MOCK_DOCKER_LOG"
printf 'invalid\n' > "$temporary_directory/repo/config/playwright-pin.txt"
expect_failure bash "$verifier" --all-backends
test ! -s "$MOCK_DOCKER_LOG"
cp "$repository_root/config/playwright-pin.txt" "$temporary_directory/repo/config/"
: > "$MOCK_DOCKER_LOG"
printf '{}\n' > "$temporary_directory/repo/config/runner-image-families.json"
expect_failure bash "$verifier" --all-backends
test ! -s "$MOCK_DOCKER_LOG"

cat > "$temporary_directory/repo/scripts/generate-workflow-matrices.sh" <<'GENERATOR'
#!/usr/bin/env bash
printf '{"family_matrix":{"include":[]}}\n'
exit 7
GENERATOR
expect_failure bash "$verifier" --all-backends
test ! -s "$MOCK_DOCKER_LOG"

echo "catalog-driven end-to-end verification passed"
