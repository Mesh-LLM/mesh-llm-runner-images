#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 7 ]] || {
  echo 'usage: validate-family-selection.sh ENVIRONMENT BACKEND_ID BACKEND_NAME CUDA_SERIES ROCM_VERSION ARCHITECTURES DOCKERFILE' >&2
  exit 2
}
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ "$6" == amd64 || "$6" == amd64,arm64 ]] || {
  echo 'unsupported workflow architecture set' >&2
  exit 1
}
matrices="$(bash "$repository_root/scripts/generate-workflow-matrices.sh")"
# A PR may narrow a two-platform family to its AMD64 contract row. All other
# fields must match one catalog family, including the closed Dockerfile choice.
jq -e --arg environment "$1" --arg id "$2" --arg name "$3" \
  --arg cuda "$4" --arg rocm "$5" --arg architectures "$6" --arg dockerfile "$7" '
  any(.family_matrix.include[];
    .environment == $environment and .backend_id == $id and .backend_name == $name
    and .cuda_series == $cuda and .rocm_version == $rocm and .dockerfile == $dockerfile
    and (($architectures | split(",")) - (.architectures | split(",")) | length == 0))
' <<< "$matrices" >/dev/null || {
  echo 'build selection does not match the runner image family catalog' >&2
  exit 1
}
