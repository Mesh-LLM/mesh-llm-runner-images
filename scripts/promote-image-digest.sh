#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: promote-image-digest.sh \
  --descriptor FILE \
  --image IMAGE \
  --environment public|self-hosted \
  --backend-id ID \
  --backend-name cpu|vulkan|cuda|rocm|mixed \
  --cuda-series none|MAJOR-MINOR \
  --rocm-version none|VERSION \
  --mesh-revision SHA \
  --runner-images-revision SHA \
  --architectures amd64[,arm64] \
  --tag IMAGE:TAG [--tag IMAGE:TAG ...] \
  [--immutable-tag IMAGE:TAG ...]
EOF
  exit 2
}

descriptor=
expected_image=
expected_environment=
expected_backend_id=
expected_backend_name=
expected_cuda_series=
expected_rocm_version=
expected_mesh_revision=
expected_runner_images_revision=
expected_architectures=
tags=()
immutable_tags=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --descriptor) descriptor="${2:-}"; shift 2 ;;
    --image) expected_image="${2:-}"; shift 2 ;;
    --environment) expected_environment="${2:-}"; shift 2 ;;
    --backend-id) expected_backend_id="${2:-}"; shift 2 ;;
    --backend-name) expected_backend_name="${2:-}"; shift 2 ;;
    --cuda-series) expected_cuda_series="${2:-}"; shift 2 ;;
    --rocm-version) expected_rocm_version="${2:-}"; shift 2 ;;
    --mesh-revision) expected_mesh_revision="${2:-}"; shift 2 ;;
    --runner-images-revision) expected_runner_images_revision="${2:-}"; shift 2 ;;
    --architectures) expected_architectures="${2:-}"; shift 2 ;;
    --tag) tags+=("${2:-}"); shift 2 ;;
    --immutable-tag) immutable_tags+=("${2:-}"); shift 2 ;;
    *) usage ;;
  esac
done

[[ "$((${#tags[@]} + ${#immutable_tags[@]}))" -gt 0 ]] || usage

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_directory/validate-candidate-descriptor.sh" \
  --descriptor "$descriptor" \
  --image "$expected_image" \
  --environment "$expected_environment" \
  --backend-id "$expected_backend_id" \
  --backend-name "$expected_backend_name" \
  --cuda-series "$expected_cuda_series" \
  --rocm-version "$expected_rocm_version" \
  --mesh-revision "$expected_mesh_revision" \
  --runner-images-revision "$expected_runner_images_revision" \
  --architectures "$expected_architectures"

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
inspection_directory="$(mktemp -d)"
trap 'rm -rf "$inspection_directory"' EXIT

digest="$(jq -er '.digest' "$descriptor")"
source_reference="${expected_image}@${digest}"
tag_arguments=()
seen_tags=()
all_tags=("${tags[@]}" "${immutable_tags[@]}")
for tag in "${all_tags[@]}"; do
  [[ "$tag" == "${expected_image}:"* ]] || {
    echo "promotion tag must target $expected_image: $tag" >&2
    exit 1
  }
  tag_name="${tag#"${expected_image}:"}"
  [[ "$tag_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
    echo "invalid OCI tag: $tag" >&2
    exit 1
  }
  for seen_tag in "${seen_tags[@]}"; do
    [[ "$tag" != "$seen_tag" ]] || {
      echo "duplicate promotion tag: $tag" >&2
      exit 1
    }
  done
  seen_tags+=("$tag")
  tag_arguments+=(--tag "$tag")
done

inspect_digest() {
  local reference="$1"
  local manifest_json
  local resolved_digest

  manifest_json="$(
    "$docker_binary" buildx imagetools inspect "$reference" \
      --format '{{json .Manifest}}'
  )"
  resolved_digest="$(
    jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
      <<< "$manifest_json"
  )" || {
    echo "registry returned no valid digest for $reference" >&2
    return 1
  }
  printf '%s\n' "$resolved_digest"
}

resolved_source_digest="$(inspect_digest "$source_reference")"
[[ "$resolved_source_digest" == "$digest" ]] || {
  echo "candidate source resolved to $resolved_source_digest, expected $digest" >&2
  exit 1
}

expected_children="$(jq -c '[.children[]] | sort_by(.architecture)' "$descriptor")"
raw_manifest="$("$docker_binary" buildx imagetools inspect "$source_reference" --raw)"
if ! jq -e \
  --argjson expected_children "$expected_children" \
  '
    try (
      .schemaVersion == 2
      and (.manifests | type == "array")
      and all(
        .manifests[];
        .platform.os == "linux"
        or (
          .platform.os == "unknown"
          and .platform.architecture == "unknown"
          and .annotations["vnd.docker.reference.type"] == "attestation-manifest"
        )
      )
      and (
        [
          .manifests[]
          | select(.platform.os == "linux")
          | {
              architecture: .platform.architecture,
              digest: .digest,
              os: .platform.os
            }
        ]
        | sort_by(.architecture)
      ) == $expected_children
    ) catch false
  ' <<< "$raw_manifest" >/dev/null; then
  echo "candidate registry index does not match descriptor children: $source_reference" >&2
  exit 1
fi

inspect_optional_tag_digest() {
  local reference="$1"
  local inspect_error
  local inspect_output
  local resolved_digest

  if inspect_output="$(
    "$docker_binary" buildx imagetools inspect "$reference" \
      --format '{{json .Manifest}}' \
      2>"$inspection_directory/immutable-tag-error"
  )"; then
    resolved_digest="$(
      jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
        <<< "$inspect_output"
    )" || {
      echo "registry returned no valid digest for immutable tag $reference" >&2
      return 1
    }
    printf '%s\n' "$resolved_digest"
    return 0
  fi
  inspect_error="$(cat "$inspection_directory/immutable-tag-error")"
  if grep -Eqi 'manifest unknown|not found' <<< "$inspect_error"; then
    return 2
  fi
  echo "failed to inspect immutable tag $reference: $inspect_error" >&2
  return 1
}

for immutable_tag in "${immutable_tags[@]}"; do
  if existing_digest="$(inspect_optional_tag_digest "$immutable_tag")"; then
    [[ "$existing_digest" == "$digest" ]] || {
      echo "immutable tag $immutable_tag already resolves to $existing_digest, expected $digest" >&2
      exit 1
    }
  else
    inspect_status=$?
    [[ "$inspect_status" -eq 2 ]] || exit "$inspect_status"
  fi
done

"$docker_binary" buildx imagetools create "${tag_arguments[@]}" "$source_reference"

for tag in "${all_tags[@]}"; do
  resolved_tag_digest="$(inspect_digest "$tag")"
  [[ "$resolved_tag_digest" == "$digest" ]] || {
    echo "promoted tag $tag resolved to $resolved_tag_digest, expected $digest" >&2
    exit 1
  }
  echo "promoted $tag -> $digest"
done
