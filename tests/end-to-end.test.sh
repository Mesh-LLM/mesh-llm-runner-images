#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
mkdir -p "$temporary_directory/bin" "$temporary_directory/repo"
cp -R "$repository_root/scripts" "$repository_root/config" "$temporary_directory/repo/"
verifier="$temporary_directory/repo/scripts/verify-end-to-end.sh"
export MOCK_DOCKER_LOG="$temporary_directory/docker.jsonl"
export MOCK_REGISTRY_STATE="$temporary_directory/registry.json"
export PATH="$temporary_directory/bin:$PATH"

reset_mock() {
  : > "$MOCK_DOCKER_LOG"
  printf '{}\n' > "$MOCK_REGISTRY_STATE"
}
reset_mock

cat > "$temporary_directory/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
jq -cn --args '$ARGS.positional' -- "$@" >> "$MOCK_DOCKER_LOG"
if [[ "$1" == buildx && "$2" == imagetools && "$3" == inspect ]]; then
  reference="$4"
  if [[ "$reference" == --raw ]]; then reference="$5"; fi
  if [[ " $* " == *' --format '* ]]; then
    [[ "$reference" != *@* ]] || exit 65
    ordinal="$(jq 'length + 1' "$MOCK_REGISTRY_STATE")"
    digest="sha256:$(printf '%064x' "$ordinal")"
    jq --arg reference "$reference" --arg digest "$digest" '
      .[$reference] = ((.[$reference] // {first_digest: $digest, current_digest: $digest, lookups: 0})
        | .lookups += 1)
    ' "$MOCK_REGISTRY_STATE" > "$MOCK_REGISTRY_STATE.next"
    mv "$MOCK_REGISTRY_STATE.next" "$MOCK_REGISTRY_STATE"
    digest="$(jq -r --arg reference "$reference" '.[$reference].current_digest' "$MOCK_REGISTRY_STATE")"
    jq -cn --arg digest "${MOCK_RESOLVED_DIGEST:-$digest}" '{digest: $digest}'
  elif [[ "$reference" == *@sha256:* ]]; then
    jq -e --arg digest "${reference##*@}" 'any(.[]; .first_digest == $digest)' "$MOCK_REGISTRY_STATE" >/dev/null
    architectures="${MOCK_ARCHITECTURES:-amd64,arm64}"
    if [[ -n "${MOCK_MIXED_ARCHITECTURES:-}" ]]; then
      alias="$(jq -er --arg digest "${reference##*@}" 'to_entries[] | select(.value.first_digest == $digest) | .key' "$MOCK_REGISTRY_STATE")"
      if [[ "$alias" == *:self-hosted-latest ]]; then architectures="$MOCK_MIXED_ARCHITECTURES"; fi
    fi
    jq -cn --arg architectures "$architectures" \
      '{manifests: [$architectures | split(",")[] | {platform: {os: "linux", architecture: .}}]}'
  else
    echo "mutable alias used for raw inspection: $reference" >&2
    exit 66
  fi
elif [[ "$1" == run ]]; then
  # Mutable local tags deliberately cannot satisfy a verification run.
  [[ "$3" == --pull=missing && "$4" == --network && "$5" == none ]]
  reference="${10}"
  [[ "$reference" == *@sha256:* ]] || exit 67
  alias="$(jq -er --arg digest "${reference##*@}" 'to_entries[] | select(.value.first_digest == $digest) | .key' "$MOCK_REGISTRY_STATE")"
  if [[ "${MOCK_ALIAS_MOVES:-false}" == true ]]; then
    jq --arg alias "$alias" '.[$alias].current_digest = ("sha256:" + ("f" * 64))' \
      "$MOCK_REGISTRY_STATE" > "$MOCK_REGISTRY_STATE.next"
    mv "$MOCK_REGISTRY_STATE.next" "$MOCK_REGISTRY_STATE"
  fi
  if [[ "$alias" == *public-web-latest ]]; then exit "${MOCK_WEB_EXIT:-0}"; fi
else
  exit 64
fi
MOCK
chmod +x "$temporary_directory/bin/docker"

bash "$verifier" --all-backends > "$temporary_directory/output"
jq -se '
  ([.[] | select(.[0] == "run")] | length) == 27
  and ([.[] | select(.[0] == "buildx")] | length) == 34
  and all(.[] | select(.[0] == "run"); length == 17)
' "$MOCK_DOCKER_LOG" >/dev/null
jq -e 'length == 17 and all(.[]; .lookups == 1)' "$MOCK_REGISTRY_STATE" >/dev/null

assert_backend() {
  local tag="$1" platform="$2" environment="$3" backend="$4"
  local cuda="$5" rocm="$6" playwright="$7"
  local digest
  digest="$(jq -er --arg alias "ghcr.io/mesh-llm/mesh-llm-cuda-runner:$tag" '.[$alias].first_digest' "$MOCK_REGISTRY_STATE")"
  jq -se --arg image "ghcr.io/mesh-llm/mesh-llm-cuda-runner@$digest" \
    --arg platform "linux/$platform" --arg environment "$environment" \
    --arg backend "$backend" --arg cuda "$cuda" --arg rocm "$rocm" \
    --arg playwright "$playwright" '
      any(.[]; .[0] == "run" and .[6] == $platform and .[9] == $image
        and .[10:] == [$environment, $backend, "", $cuda, $rocm, "", $playwright])
    ' "$MOCK_DOCKER_LOG" >/dev/null
}
assert_backend public-web-latest amd64 public web none none "$(cat "$repository_root/config/playwright-pin.txt")"
assert_backend public-ui-latest amd64 public ui none none none
assert_backend public-browser-latest amd64 public browser none none "$(cat "$repository_root/config/playwright-pin.txt")"
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
for backend in web ui browser; do
  printf 'public-%s-latest\tlinux/amd64\n' "$backend" >> "$expected_rows"
done
for tag in public self-hosted; do
  for architecture in amd64 arm64; do
    printf '%s-latest\tlinux/%s\n' "$tag" "$architecture"
  done
done >> "$expected_rows"
jq -sr --slurpfile registry "$MOCK_REGISTRY_STATE" '
  .[] | select(.[0] == "run") | . as $run
  | ($registry[0] | to_entries[] | select(.value.first_digest == ($run[9] | split("@")[1])) | .key) as $alias
  | [($alias | split(":")[-1]), .[6]] | @tsv' \
  "$MOCK_DOCKER_LOG" | sort > "$temporary_directory/actual.tsv"
sort "$expected_rows" > "$temporary_directory/expected-sorted.tsv"
diff -u "$temporary_directory/expected-sorted.tsv" "$temporary_directory/actual.tsv"

reset_mock
PUBLIC_TAG=public-custom SELF_HOSTED_TAG=self-hosted-custom bash "$verifier" >/dev/null
jq -se '
  ([.[] | select(.[0] == "run")] | length) == 4
  and ([.[] | select(.[0] == "buildx")] | length) == 4
' "$MOCK_DOCKER_LOG" >/dev/null
jq -e 'length == 2 and all(keys[]; endswith("-custom"))' "$MOCK_REGISTRY_STATE" >/dev/null

# The same alias selected twice must be resolved once, even if it moves while
# its first architecture is executing. Subsequent runs keep the first digest.
reset_mock
PUBLIC_TAG=public-cpu-latest MOCK_ALIAS_MOVES=true bash "$verifier" --all-backends >/dev/null
jq -e 'length == 16 and all(.[]; .lookups == 1 and .first_digest != .current_digest)' "$MOCK_REGISTRY_STATE" >/dev/null
assert_backend public-cpu-latest amd64 public cpu none none none
assert_backend public-cpu-latest arm64 public cpu none none none
assert_backend self-hosted-latest amd64 self-hosted cuda 12-9 none none
assert_backend self-hosted-latest arm64 self-hosted cpu none none none

# Optional independent source expectations keep the established seven args.
mesh_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
runner_revision=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
reset_mock
bash "$verifier" --mesh-revision "$mesh_revision" --runner-images-revision "$runner_revision" >/dev/null
jq -se --arg mesh "$mesh_revision" --arg runner "$runner_revision" '
  all(.[] | select(.[0] == "run"); .[12] == $mesh and .[15] == $runner)
' "$MOCK_DOCKER_LOG" >/dev/null
reset_mock
bash "$verifier" --mesh-revision "$mesh_revision" >/dev/null
jq -se --arg mesh "$mesh_revision" '
  all(.[] | select(.[0] == "run"); .[12] == $mesh and .[15] == "")
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
reset_mock
expect_failure env MOCK_RESOLVED_DIGEST=invalid bash "$verifier"
jq -se 'length == 1 and all(.[]; .[0] != "run")' "$MOCK_DOCKER_LOG" >/dev/null
reset_mock
expect_failure bash "$verifier" --unknown
test ! -s "$MOCK_DOCKER_LOG"
for option in --mesh-revision --runner-images-revision; do
  for value in short AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ''; do
    expect_failure bash "$verifier" "$option" "$value"
    test ! -s "$MOCK_DOCKER_LOG"
  done
  expect_failure bash "$verifier" "$option"
  test ! -s "$MOCK_DOCKER_LOG"
done

# Version expectations must follow the catalog, not a second hardcoded list.
catalog="$temporary_directory/repo/config/runner-image-families.json"
jq '(.backends[] | select(.id == "cuda12") | .cuda_series) = "12-8"' \
  "$catalog" > "$temporary_directory/catalog.json"
cp "$temporary_directory/catalog.json" "$catalog"
printf '1.60.0\n' > "$temporary_directory/repo/config/playwright-pin.txt"
reset_mock
bash "$verifier" --all-backends >/dev/null
assert_backend public-web-latest amd64 public web none none 1.60.0
assert_backend public-browser-latest amd64 public browser none none 1.60.0
assert_backend self-hosted-latest amd64 self-hosted cuda 12-8 none none

# Mixed child selection follows explicit catalog sources, independently of SDK pins.
jq '(.indexes[] | select(.artifact == "candidate-index-self-hosted-compatibility") | .sources[] | select(.architecture == "amd64") | .backend_id) = "cuda13"' \
  "$catalog" > "$temporary_directory/catalog.json"
cp "$temporary_directory/catalog.json" "$catalog"
reset_mock
bash "$verifier" >/dev/null
assert_backend self-hosted-latest amd64 self-hosted cuda 13-1 none none
assert_backend self-hosted-latest arm64 self-hosted cpu none none none

# A catalog-valid one-platform compatibility index requires only that platform.
jq '(.indexes[] | select(.artifact == "candidate-index-self-hosted-compatibility")) |= (.architectures = ["amd64"] | .sources |= map(select(.architecture == "amd64")))' \
  "$catalog" > "$temporary_directory/catalog.json"
cp "$temporary_directory/catalog.json" "$catalog"
reset_mock
MOCK_MIXED_ARCHITECTURES=amd64 bash "$verifier" >/dev/null
assert_backend self-hosted-latest amd64 self-hosted cuda 13-1 none none
jq -se '([.[] | select(.[0] == "run")] | length) == 3' "$MOCK_DOCKER_LOG" >/dev/null

reset_mock
printf 'invalid\n' > "$temporary_directory/repo/config/playwright-pin.txt"
expect_failure bash "$verifier" --all-backends
test ! -s "$MOCK_DOCKER_LOG"
cp "$repository_root/config/playwright-pin.txt" "$temporary_directory/repo/config/"
reset_mock
printf '{}\n' > "$temporary_directory/repo/config/runner-image-families.json"
expect_failure bash "$verifier" --all-backends
test ! -s "$MOCK_DOCKER_LOG"

cp "$repository_root/config/runner-image-families.json" \
  "$temporary_directory/repo/config/runner-image-families.json"
export MOCK_GENERATOR_LOG="$temporary_directory/generator.log"
cat > "$temporary_directory/repo/scripts/generate-workflow-matrices.sh" <<'GENERATOR'
#!/usr/bin/env bash
touch "$MOCK_GENERATOR_LOG"
printf '{"family_matrix":{"include":[]}}\n'
exit 7
GENERATOR
expect_failure bash "$verifier" --all-backends
test -f "$MOCK_GENERATOR_LOG"
test ! -s "$MOCK_DOCKER_LOG"

echo "catalog-driven end-to-end verification passed"
