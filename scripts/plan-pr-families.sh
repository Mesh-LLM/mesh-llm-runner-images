#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
descriptor="${1:-$repository_root/config/runner-image-families.json}"
changed_files="${2:-}"

[[ -f "$descriptor" ]] || {
  echo "runner image family descriptor does not exist: $descriptor" >&2
  exit 1
}
[[ -f "$changed_files" ]] || {
  echo "changed-file list does not exist: $changed_files" >&2
  exit 1
}

all_families=false
public_environment=false
self_hosted_environment=false
cpu_backend=false
vulkan_backend=false
cuda12_backend=false
cuda13_backend=false
rocm70_backend=false
rocm72_backend=false
changed_count=0

while IFS= read -r changed_file; do
  [[ -n "$changed_file" ]] || continue
  changed_count=$((changed_count + 1))
  case "$changed_file" in
    Dockerfile|Dockerfile.verify|.dockerignore|config/*|profiles/common.yml)
      all_families=true
      ;;
    profiles/public.yml)
      public_environment=true
      ;;
    profiles/self-hosted.yml|scripts/install-actions-runner.sh)
      self_hosted_environment=true
      ;;
    profiles/backends/cpu.yml)
      cpu_backend=true
      ;;
    profiles/backends/vulkan.yml)
      vulkan_backend=true
      ;;
    profiles/backends/cuda.yml|scripts/install-cuda-toolchain.sh)
      cuda12_backend=true
      cuda13_backend=true
      ;;
    profiles/backends/rocm.yml|scripts/install-rocm-toolchain.sh)
      rocm70_backend=true
      rocm72_backend=true
      ;;
    scripts/collect-manifests.sh|scripts/install-core-tools.sh|scripts/prepare-build-context.sh|scripts/profile-packages.sh|scripts/verify-runner-image.sh|scripts/warm-dependencies.sh)
      all_families=true
      ;;
    .github/*|docs/*|tests/*|README.md|LICENSE|scripts/generate-*|scripts/install-actionlint.sh|scripts/plan-pr-families.sh|scripts/promote-*|scripts/reconcile-*|scripts/select-*|scripts/validate-*|scripts/verify-end-to-end.sh)
      # Workflow, policy, test, and documentation changes still receive the
      # always-on public CPU AMD64 contract row below.
      ;;
    *)
      # Unknown image inputs fail open to exhaustive validation.
      all_families=true
      ;;
  esac
done < "$changed_files"

if [[ "$changed_count" -eq 0 ]]; then
  all_families=true
fi

backends_json="$(
  {
    if [[ "$cpu_backend" == true ]]; then printf 'cpu\n'; fi
    if [[ "$vulkan_backend" == true ]]; then printf 'vulkan\n'; fi
    if [[ "$cuda12_backend" == true ]]; then printf 'cuda12\n'; fi
    if [[ "$cuda13_backend" == true ]]; then printf 'cuda13\n'; fi
    if [[ "$rocm70_backend" == true ]]; then printf 'rocm70\n'; fi
    if [[ "$rocm72_backend" == true ]]; then printf 'rocm72\n'; fi
  } | jq -R . | jq -sc .
)"

matrices="$(bash "$repository_root/scripts/generate-workflow-matrices.sh" "$descriptor")"
jq -ce \
  --argjson all_families "$all_families" \
  --argjson public_environment "$public_environment" \
  --argjson self_hosted_environment "$self_hosted_environment" \
  --argjson backends "$backends_json" \
  --argjson changed_count "$changed_count" \
  '
    .family_matrix.include as $all
    | (
        if $all_families then
          $all
        else
          [
            $all[]
            | select(
                (.environment == "public" and $public_environment)
                or (.environment == "self-hosted" and $self_hosted_environment)
                or (.backend_id as $id | $backends | index($id))
              )
          ]
        end
      ) as $selected
    | (
        if any($selected[]; .environment == "public" and .backend_id == "cpu") then
          $selected
        else
          $selected + [
            $all[]
            | select(.environment == "public" and .backend_id == "cpu")
            | .architectures = "amd64"
          ]
        end
      ) as $with_contract
    | {
        family_matrix: {
          include: $with_contract
        },
        selection: {
          exhaustive: $all_families,
          changed_files: $changed_count,
          selected_families: ($with_contract | length)
        }
      }
  ' <<< "$matrices"
