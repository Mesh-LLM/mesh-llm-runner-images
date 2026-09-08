#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 2 ]] || { echo 'usage: publish-runner-cohort.sh COHORT NEW_OUTPUT_DIRECTORY' >&2; exit 2; }
script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cohort="$1"
output="$2"
python3 "$script_directory/runner-cohort.py" export --cohort "$cohort" --directory "$output"
image="$(jq -er '.image' "$cohort")"
mesh_revision="$(jq -er '.mesh_revision' "$output/origin.json")"
runner_images_revision="$(jq -er '.runner_images_revision' "$output/origin.json")"
timestamp="$(jq -er '.timestamp' "$output/origin.json")"
# Materialize checked output before iteration; producer failures must propagate.
jq -cer '.include[]' "$output/promotion-matrix.json" > "$output/rows.ndjson"
while IFS= read -r row; do
  artifact="$(jq -er '.artifact' <<< "$row")"
  descriptor="$output/$artifact.json"
  content_digest="$(jq -er '.digest' "$descriptor")"
  bash "$script_directory/generate-promotion-tags.sh" versioned "$image" \
    "$(jq -er '.tag_stem' <<< "$row")" "$(jq -r '.compatibility_tag_stem' <<< "$row")" \
    "$timestamp" "$mesh_revision" "$runner_images_revision" "$content_digest" > "$output/tags.txt"
  mapfile -t tags < "$output/tags.txt"
  bash "$script_directory/promote-image-digest.sh" \
    --descriptor "$descriptor" --image "$image" \
    --environment "$(jq -er '.environment' <<< "$row")" \
    --backend-id "$(jq -er '.backend_id' <<< "$row")" \
    --backend-name "$(jq -er '.backend_name' <<< "$row")" \
    --cuda-series "$(jq -er '.cuda_series' <<< "$row")" \
    --rocm-version "$(jq -er '.rocm_version' <<< "$row")" \
    --architectures "$(jq -er '.architectures' <<< "$row")" \
    --mesh-revision "$mesh_revision" --runner-images-revision "$runner_images_revision" \
    "${tags[@]}"
done < "$output/rows.ndjson"
bash "$script_directory/generate-latest-cohort.sh" --descriptors "$output" \
  --matrix "$output/promotion-matrix.json" --image "$image" --timestamp "$timestamp" \
  --mesh-revision "$mesh_revision" --runner-images-revision "$runner_images_revision" \
  --output "$output/latest-cohort.json"
