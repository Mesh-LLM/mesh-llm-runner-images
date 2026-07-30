#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: generate-latest-cohort.sh \
  --descriptors DIRECTORY \
  --matrix FILE \
  --image IMAGE \
  --timestamp TIMESTAMP \
  --mesh-revision SHA \
  --runner-images-revision SHA \
  --output FILE
EOF
  exit 2
}

descriptor_directory=
matrix_file=
image=
timestamp=
mesh_revision=
runner_images_revision=
output=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --descriptors) descriptor_directory="${2:-}"; shift 2 ;;
    --matrix) matrix_file="${2:-}"; shift 2 ;;
    --image) image="${2:-}"; shift 2 ;;
    --timestamp) timestamp="${2:-}"; shift 2 ;;
    --mesh-revision) mesh_revision="${2:-}"; shift 2 ;;
    --runner-images-revision) runner_images_revision="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$descriptor_directory" && -f "$matrix_file" && -n "$output" ]] || usage
[[ "$image" =~ ^ghcr\.io/[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$ ]] || {
  echo "image must be an untagged lowercase ghcr.io repository" >&2
  exit 1
}
[[ "$timestamp" =~ ^[0-9]{14}$ ]] || {
  echo "timestamp must contain 14 UTC date digits" >&2
  exit 1
}
[[ "$mesh_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "MeshLLM revision must be a full lowercase git SHA" >&2
  exit 1
}
[[ "$runner_images_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "runner-images revision must be a full lowercase git SHA" >&2
  exit 1
}

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}
docker_binary="${DOCKER_BIN:-docker}"
if [[ "$docker_binary" == */* ]]; then
  [[ -x "$docker_binary" ]] || {
    echo "Docker command is not executable: $docker_binary" >&2
    exit 1
  }
else
  command -v "$docker_binary" >/dev/null || {
    echo "Docker command is unavailable: $docker_binary" >&2
    exit 1
  }
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
entries_file="$temporary_directory/entries.ndjson"
touch "$entries_file"
seen_tags=()

inspect_optional_digest() {
  local error_file="$1"
  local reference="$2"
  local manifest_json

  if manifest_json="$(
    "$docker_binary" buildx imagetools inspect "$reference" \
      --format '{{json .Manifest}}' 2>"$error_file"
  )"; then
    jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
      <<< "$manifest_json"
    return 0
  fi
  if grep -Eqi 'manifest unknown|not found' "$error_file"; then
    printf 'null\n'
    return 0
  fi
  echo "failed to inspect existing latest tag $reference: $(cat "$error_file")" >&2
  return 1
}

while IFS=$'\t' read -r environment backend_id backend_name cuda_series \
  rocm_version architectures artifact tag_stem compatibility_tag_stem; do
  descriptor="$descriptor_directory/${artifact}.json"
  [[ -f "$descriptor" ]] || {
    echo "missing candidate descriptor for cohort: $descriptor" >&2
    exit 1
  }
  bash "$script_directory/validate-candidate-descriptor.sh" \
    --descriptor "$descriptor" \
    --image "$image" \
    --environment "$environment" \
    --backend-id "$backend_id" \
    --backend-name "$backend_name" \
    --cuda-series "$cuda_series" \
    --rocm-version "$rocm_version" \
    --mesh-revision "$mesh_revision" \
    --runner-images-revision "$runner_images_revision" \
    --architectures "$architectures"

  target_digest="$(jq -er '.digest' "$descriptor")"
  mapfile -t latest_arguments < <(
    bash "$script_directory/generate-promotion-tags.sh" \
      latest \
      "$image" \
      "$tag_stem" \
      "$compatibility_tag_stem" \
      "$timestamp" \
      "$mesh_revision" \
      "$runner_images_revision" \
      "$target_digest"
  )
  [[ "$((${#latest_arguments[@]} % 2))" -eq 0 ]]
  for ((index = 0; index < ${#latest_arguments[@]}; index += 2)); do
    [[ "${latest_arguments[$index]}" == --tag ]] || {
      echo "latest cohort received a non-mutable tag mode" >&2
      exit 1
    }
    tag="${latest_arguments[$((index + 1))]}"
    for seen_tag in "${seen_tags[@]}"; do
      [[ "$tag" != "$seen_tag" ]] || {
        echo "duplicate latest cohort tag: $tag" >&2
        exit 1
      }
    done
    seen_tags+=("$tag")
    error_file="$temporary_directory/inspect-${#seen_tags[@]}.log"
    previous_digest="$(inspect_optional_digest "$error_file" "$tag")"
    jq -cn \
      --arg artifact "$artifact" \
      --arg tag "$tag" \
      --arg target_digest "$target_digest" \
      --arg previous_digest "$previous_digest" \
      '{
        artifact: $artifact,
        tag: $tag,
        target_digest: $target_digest,
        previous_digest: (
          if $previous_digest == "null"
          then null
          else $previous_digest
          end
        )
      }' >> "$entries_file"
  done
done < <(
  jq -er '
    .include[]
    | [
        .environment,
        .backend_id,
        .backend_name,
        .cuda_series,
        .rocm_version,
        .architectures,
        .artifact,
        .tag_stem,
        .compatibility_tag_stem
      ]
    | @tsv
  ' "$matrix_file"
)

[[ "${#seen_tags[@]}" -gt 0 ]] || {
  echo "latest cohort contains no tags" >&2
  exit 1
}

jq -s \
  --arg image "$image" \
  --arg timestamp "$timestamp" \
  --arg mesh_revision "$mesh_revision" \
  --arg runner_images_revision "$runner_images_revision" \
  '{
    schema: 1,
    type: "mesh-llm-runner-image-latest-cohort",
    image: $image,
    timestamp: $timestamp,
    mesh_revision: $mesh_revision,
    runner_images_revision: $runner_images_revision,
    entries: sort_by(.tag)
  }' "$entries_file" > "$output"
