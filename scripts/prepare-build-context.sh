#!/usr/bin/env bash
set -euo pipefail

source_repository="${1:?usage: prepare-build-context.sh SOURCE_REPOSITORY [OUTPUT_ROOT]}"
output_root="${2:-build-context/manifests}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for profile in public self-hosted; do
  "$script_dir/collect-manifests.sh" \
    --source "$source_repository" \
    --output "$output_root/$profile" \
    --profile "$profile"
done
