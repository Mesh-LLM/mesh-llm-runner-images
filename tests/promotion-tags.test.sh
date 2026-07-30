#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="$repository_root/scripts/generate-promotion-tags.sh"
image=ghcr.io/mesh-llm/mesh-llm-cuda-runner
timestamp=20260729123456
mesh_revision=2222222222222222222222222222222222222222
runner_images_revision=1111111111111111111111111111111111111111
content_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
content_digest_hex="${content_digest#sha256:}"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

mapfile -t versioned_tags < <(
  bash "$generator" versioned "$image" public-cpu public \
    "$timestamp" "$mesh_revision" "$runner_images_revision" "$content_digest"
)
expected_versioned_tags=(
  --tag
  "$image:public-cpu-$timestamp"
  --tag
  "$image:public-cpu-sha-222222222222"
  --immutable-tag
  "$image:public-cpu-digest-sha256-$content_digest_hex"
  --tag
  "$image:public-$timestamp"
  --tag
  "$image:public-sha-222222222222"
  --immutable-tag
  "$image:public-digest-sha256-$content_digest_hex"
)
[[ "${versioned_tags[*]}" == "${expected_versioned_tags[*]}" ]]

mapfile -t latest_tags < <(
  bash "$generator" latest "$image" public-cpu public \
    "$timestamp" "$mesh_revision" "$runner_images_revision" "$content_digest"
)
expected_latest_tags=(
  --tag
  "$image:public-cpu-latest"
  --tag
  "$image:public-latest"
)
[[ "${latest_tags[*]}" == "${expected_latest_tags[*]}" ]]

mapfile -t no_alias_tags < <(
  bash "$generator" versioned "$image" public-cuda12 "" \
    "$timestamp" "$mesh_revision" "$runner_images_revision" "$content_digest"
)
[[ "${#no_alias_tags[@]}" -eq 6 ]]
[[ "${no_alias_tags[3]}" == "$image:public-cuda12-sha-222222222222" ]]
[[ "${no_alias_tags[5]}" == \
  "$image:public-cuda12-digest-sha256-$content_digest_hex" ]]

expect_failure bash "$generator" versioned "$image" public-cpu public \
  "$timestamp" short "$runner_images_revision" "$content_digest"
expect_failure bash "$generator" versioned "$image" public-cpu public-cpu \
  "$timestamp" "$mesh_revision" "$runner_images_revision" "$content_digest"
expect_failure bash "$generator" candidate "$image" public-cpu public \
  "$timestamp" "$mesh_revision" "$runner_images_revision" "$content_digest"
expect_failure bash "$generator" versioned "$image" public-cpu public \
  "$timestamp" "$mesh_revision" "$runner_images_revision" sha256:short

echo "promotion tag contract passed"
