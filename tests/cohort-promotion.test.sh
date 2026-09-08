#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="$repository_root/scripts/generate-latest-cohort.sh"
reconciler="$repository_root/scripts/reconcile-image-cohort.sh"
mock_docker="$repository_root/tests/fixtures/mock-docker.sh"
fixture="$repository_root/tests/fixtures/candidate-index-valid.json"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

image=ghcr.io/mesh-llm/mesh-llm-cuda-runner
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mesh_revision=2222222222222222222222222222222222222222
runner_images_revision=1111111111111111111111111111111111111111
timestamp=20260729123456
descriptor_directory="$temporary_directory/descriptors"
mkdir -p "$descriptor_directory"
cp "$fixture" "$descriptor_directory/candidate-index-public-cuda12.json"

jq -n '{
  include: [{
    environment: "public",
    backend_id: "cuda12",
    backend_name: "cuda",
    cuda_series: "12-9",
    rocm_version: "none",
    architectures: "amd64,arm64",
    artifact: "candidate-index-public-cuda12",
    tag_stem: "public-cuda12",
    compatibility_tag_stem: ""
  }]
}' > "$temporary_directory/matrix.json"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

generation_log="$temporary_directory/generate.log"
MOCK_DOCKER_LOG="$generation_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
DOCKER_BIN="$mock_docker" \
  bash "$generator" \
    --descriptors "$descriptor_directory" \
    --matrix "$temporary_directory/matrix.json" \
    --image "$image" \
    --timestamp "$timestamp" \
    --mesh-revision "$mesh_revision" \
    --runner-images-revision "$runner_images_revision" \
    --output "$temporary_directory/cohort.json"

jq -e \
  --arg digest "$digest" \
  --arg image "$image" \
  '
    .schema == 1
    and .type == "mesh-llm-runner-image-latest-cohort"
    and .image == $image
    and .entries == [{
      artifact: "candidate-index-public-cuda12",
      tag: ($image + ":public-cuda12-latest"),
      target_digest: $digest,
      previous_digest: $digest
    }]
  ' "$temporary_directory/cohort.json" >/dev/null

reconcile_log="$temporary_directory/reconcile.log"
MOCK_DOCKER_LOG="$reconcile_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
DOCKER_BIN="$mock_docker" \
  bash "$reconciler" "$temporary_directory/cohort.json" target
grep -Fq "buildx imagetools create --tag $image:public-cuda12-latest" \
  "$reconcile_log"

missing_previous_log="$temporary_directory/missing-previous.log"
MOCK_DOCKER_LOG="$missing_previous_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
MOCK_DOCKER_MISSING_TAG_PATTERN="-latest" \
DOCKER_BIN="$mock_docker" \
  bash "$generator" \
    --descriptors "$descriptor_directory" \
    --matrix "$temporary_directory/matrix.json" \
    --image "$image" \
    --timestamp "$timestamp" \
    --mesh-revision "$mesh_revision" \
    --runner-images-revision "$runner_images_revision" \
    --output "$temporary_directory/new-cohort.json"
jq -e '.entries[0].previous_digest == null' \
  "$temporary_directory/new-cohort.json" >/dev/null

duplicate_manifest="$temporary_directory/duplicate.json"
jq '.entries += [.entries[0]]' "$temporary_directory/cohort.json" \
  > "$duplicate_manifest"
expect_failure env \
  MOCK_DOCKER_LOG="$temporary_directory/duplicate.log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  DOCKER_BIN="$mock_docker" \
  bash "$reconciler" "$duplicate_manifest" target

previous_digest=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mixed_manifest="$temporary_directory/mixed-previous.json"
jq --arg image "$image" --arg previous_digest "$previous_digest" '
  .entries[0].previous_digest = $previous_digest
  | .entries += [{
      artifact: "candidate-index-public-web",
      tag: ($image + ":public-web-latest"),
      target_digest: .entries[0].target_digest,
      previous_digest: null
    }]
' "$temporary_directory/cohort.json" > "$mixed_manifest"

# A newly introduced tag must not prevent the existing tags from rolling
# back, regardless of whether the absent entry comes first or last.
for absent_first in false true; do
  rollback_manifest="$temporary_directory/rollback-$absent_first.json"
  rollback_log="$temporary_directory/rollback-$absent_first.log"
  rollback_error="$temporary_directory/rollback-$absent_first.err"
  jq --argjson absent_first "$absent_first" '
    if $absent_first then .entries |= reverse else . end
  ' "$mixed_manifest" > "$rollback_manifest"
  if MOCK_DOCKER_LOG="$rollback_log" \
    MOCK_DOCKER_SOURCE_DIGEST="$previous_digest" \
    DOCKER_BIN="$mock_docker" \
    bash "$reconciler" "$rollback_manifest" previous 2>"$rollback_error"; then
    :
  else
    status=$?
    echo "mixed rollback failed with absent_first=$absent_first: exit $status" >&2
    cat "$rollback_error" >&2
    exit "$status"
  fi
  [[ "$(grep -c '^buildx imagetools create ' "$rollback_log")" -eq 1 ]]
  grep -Fq \
    "buildx imagetools create --tag $image:public-cuda12-latest $image@$previous_digest" \
    "$rollback_log"
  grep -Fq "rollback leaves previously absent tag unchanged: $image:public-web-latest" \
    "$rollback_error"
done

all_absent_manifest="$temporary_directory/all-absent.json"
all_absent_log="$temporary_directory/all-absent.log"
jq '.entries[].previous_digest = null' "$mixed_manifest" > "$all_absent_manifest"
MOCK_DOCKER_LOG="$all_absent_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
DOCKER_BIN="$mock_docker" \
  bash "$reconciler" "$all_absent_manifest" previous
[[ ! -s "$all_absent_log" ]]

# Nullable previous digests do not permit malformed values or missing fields.
for mutation in '.entries[0].previous_digest = "invalid"' \
  '.entries[0].previous_digest = false' 'del(.entries[0].previous_digest)'; do
  invalid_previous_manifest="$temporary_directory/invalid-previous.json"
  invalid_previous_log="$temporary_directory/invalid-previous.log"
  jq "$mutation" "$mixed_manifest" > "$invalid_previous_manifest"
  expect_failure env \
    MOCK_DOCKER_LOG="$invalid_previous_log" \
    MOCK_DOCKER_SOURCE_DIGEST="$digest" \
    DOCKER_BIN="$mock_docker" \
    bash "$reconciler" "$invalid_previous_manifest" previous
  [[ ! -s "$invalid_previous_log" ]]
done

# If a later source fails preflight, no earlier tag may have been restored.
preflight_manifest="$temporary_directory/preflight.json"
preflight_log="$temporary_directory/preflight.log"
jq --arg digest "$digest" --arg previous_digest "$previous_digest" '
  .entries[0].previous_digest = $digest
  | .entries[1].previous_digest = $previous_digest
' "$mixed_manifest" > "$preflight_manifest"
expect_failure env \
  MOCK_DOCKER_LOG="$preflight_log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  DOCKER_BIN="$mock_docker" \
  bash "$reconciler" "$preflight_manifest" previous
[[ "$(grep -c '^buildx imagetools inspect ' "$preflight_log")" -eq 2 ]]
if grep -q '^buildx imagetools create ' "$preflight_log"; then
  echo "rollback changed a tag before every source passed preflight" >&2
  exit 1
fi

echo "latest cohort reconciliation contract passed"

# A jq or tag-generator failure must not silently truncate the cohort.
jq '.include += [1]' "$temporary_directory/matrix.json" > "$temporary_directory/malformed-matrix.json"
jq '.include[0].tag_stem = "invalid:stem"' "$temporary_directory/matrix.json" > "$temporary_directory/invalid-tag-matrix.json"
for invalid_matrix in malformed invalid-tag; do
  expect_failure env \
    MOCK_DOCKER_LOG="$temporary_directory/$invalid_matrix.log" \
    MOCK_DOCKER_SOURCE_DIGEST="$digest" DOCKER_BIN="$mock_docker" \
    bash "$generator" \
      --descriptors "$descriptor_directory" \
      --matrix "$temporary_directory/$invalid_matrix-matrix.json" \
      --image "$image" --timestamp "$timestamp" \
      --mesh-revision "$mesh_revision" --runner-images-revision "$runner_images_revision" \
      --output "$temporary_directory/$invalid_matrix-output.json"
  [[ ! -e "$temporary_directory/$invalid_matrix-output.json" ]]
done
