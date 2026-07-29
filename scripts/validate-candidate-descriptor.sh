#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: validate-candidate-descriptor.sh \
  --descriptor FILE \
  --image IMAGE \
  --environment public|self-hosted \
  --backend-id ID \
  --backend-name cpu|vulkan|cuda|rocm|mixed \
  --cuda-series none|MAJOR-MINOR \
  --rocm-version none|VERSION \
  --mesh-revision SHA \
  --runner-images-revision SHA \
  --architectures amd64[,arm64]
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
expected_architectures_csv=

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
    --architectures) expected_architectures_csv="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

for required_value in \
  "$descriptor" \
  "$expected_image" \
  "$expected_environment" \
  "$expected_backend_id" \
  "$expected_backend_name" \
  "$expected_cuda_series" \
  "$expected_rocm_version" \
  "$expected_mesh_revision" \
  "$expected_runner_images_revision" \
  "$expected_architectures_csv"; do
  [[ -n "$required_value" ]] || usage
done

[[ -f "$descriptor" ]] || {
  echo "candidate descriptor does not exist: $descriptor" >&2
  exit 1
}
command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}

[[ "$expected_image" =~ ^ghcr\.io/[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$ ]] || {
  echo "expected image must be an untagged lowercase ghcr.io repository" >&2
  exit 1
}
[[ "$expected_environment" == public || "$expected_environment" == self-hosted ]] || {
  echo "unsupported expected environment: $expected_environment" >&2
  exit 1
}
[[ "$expected_backend_id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "invalid expected backend id: $expected_backend_id" >&2
  exit 1
}
[[ "$expected_backend_name" =~ ^(cpu|vulkan|cuda|rocm|mixed)$ ]] || {
  echo "unsupported expected backend name: $expected_backend_name" >&2
  exit 1
}
[[ "$expected_cuda_series" == none || "$expected_cuda_series" =~ ^[0-9]+-[0-9]+$ ]] || {
  echo "expected CUDA series must be 'none' or MAJOR-MINOR" >&2
  exit 1
}
[[ "$expected_rocm_version" == none || "$expected_rocm_version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || {
  echo "expected ROCm version must be 'none' or a dotted numeric version" >&2
  exit 1
}
[[ "$expected_mesh_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected MeshLLM revision must be a full lowercase git SHA" >&2
  exit 1
}
[[ "$expected_runner_images_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected runner-images revision must be a full lowercase git SHA" >&2
  exit 1
}

case "$expected_backend_name" in
  cpu) [[ "$expected_backend_id" == cpu && "$expected_cuda_series" == none && "$expected_rocm_version" == none ]] ;;
  vulkan) [[ "$expected_backend_id" == vulkan && "$expected_cuda_series" == none && "$expected_rocm_version" == none ]] ;;
  cuda) [[ "$expected_backend_id" =~ ^cuda[0-9]+$ && "$expected_cuda_series" != none && "$expected_rocm_version" == none ]] ;;
  rocm) [[ "$expected_backend_id" =~ ^rocm[0-9]+$ && "$expected_cuda_series" == none && "$expected_rocm_version" != none ]] ;;
  mixed) [[ "$expected_backend_id" == compatibility && "$expected_cuda_series" == none && "$expected_rocm_version" == none ]] ;;
esac || {
  echo "expected backend id and metadata are inconsistent" >&2
  exit 1
}

[[ "$expected_architectures_csv" =~ ^(amd64|arm64)(,(amd64|arm64))*$ ]] || {
  echo "expected architectures must be a comma-separated amd64/arm64 list" >&2
  exit 1
}
IFS=',' read -r -a expected_architectures <<< "$expected_architectures_csv"
[[ "${#expected_architectures[@]}" -gt 0 ]] || {
  echo "at least one expected architecture is required" >&2
  exit 1
}
declare -A seen_architectures=()
for architecture in "${expected_architectures[@]}"; do
  [[ "$architecture" == amd64 || "$architecture" == arm64 ]] || {
    echo "unsupported expected architecture: $architecture" >&2
    exit 1
  }
  [[ -z "${seen_architectures[$architecture]:-}" ]] || {
    echo "duplicate expected architecture: $architecture" >&2
    exit 1
  }
  seen_architectures["$architecture"]=1
done
expected_architectures_json="$(
  printf '%s\n' "${expected_architectures[@]}" \
    | jq -R . \
    | jq -sc 'sort'
)"

if ! jq -e \
  --arg expected_image "$expected_image" \
  --arg expected_environment "$expected_environment" \
  --arg expected_backend_id "$expected_backend_id" \
  --arg expected_backend_name "$expected_backend_name" \
  --arg expected_cuda_series "$expected_cuda_series" \
  --arg expected_rocm_version "$expected_rocm_version" \
  --arg expected_mesh_revision "$expected_mesh_revision" \
  --arg expected_runner_images_revision "$expected_runner_images_revision" \
  --argjson expected_architectures "$expected_architectures_json" \
  '
    def exact_keys($expected): (keys | sort) == ($expected | sort);
    def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
    try (
      type == "object"
      and exact_keys([
        "backend",
        "children",
        "digest",
        "environment",
        "image",
        "mesh_revision",
        "runner_images_revision",
        "schema",
        "type"
      ])
      and .schema == 1
      and .type == "mesh-llm-runner-image-candidate"
      and .image == $expected_image
      and .environment == $expected_environment
      and .mesh_revision == $expected_mesh_revision
      and .runner_images_revision == $expected_runner_images_revision
      and (.digest | digest)
      and (
        .backend
        | type == "object"
        and exact_keys(["cuda_series", "id", "name", "rocm_version"])
        and .id == $expected_backend_id
        and .name == $expected_backend_name
        and .cuda_series == (if $expected_cuda_series == "none" then null else $expected_cuda_series end)
        and .rocm_version == (if $expected_rocm_version == "none" then null else $expected_rocm_version end)
      )
      and (.children | type == "array" and length > 0)
      and all(
        .children[];
        type == "object"
        and exact_keys(["architecture", "digest", "os"])
        and .os == "linux"
        and (.architecture == "amd64" or .architecture == "arm64")
        and (.digest | digest)
      )
      and (([.children[].architecture] | length) == ([.children[].architecture] | unique | length))
      and (([.children[].digest] | length) == ([.children[].digest] | unique | length))
      and ([.children[].architecture] | sort) == $expected_architectures
    ) catch false
  ' "$descriptor" >/dev/null; then
  echo "candidate descriptor failed schema or expected-value validation: $descriptor" >&2
  exit 1
fi
