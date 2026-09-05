#!/usr/bin/env bash
set -euo pipefail

repository_root="${1:-.}"
[[ -d "$repository_root" ]] || {
  echo "Docker build context root does not exist: $repository_root" >&2
  exit 1
}

# Keep this estimate aligned with the repository's current .dockerignore. It
# reports content bytes, not tar/protocol overhead or time spent uploading to
# Depot; those phases are not exposed separately by the build action.
context_files=(
  "$repository_root/Dockerfile"
  "$repository_root/Dockerfile.verify"
)
while IFS= read -r -d '' path; do
  context_files+=("$path")
done < <(
  find "$repository_root/profiles" \
    "$repository_root/scripts" \
    "$repository_root/build-context" \
    -type f -print0 2>/dev/null
)

content_bytes=0
file_count=0
for path in "${context_files[@]}"; do
  [[ -f "$path" ]] || {
    echo "Docker build context file does not exist: $path" >&2
    exit 1
  }
  file_bytes="$(wc -c < "$path")"
  content_bytes=$((content_bytes + file_bytes))
  file_count=$((file_count + 1))
done

jq -cn \
  --argjson content_bytes "$content_bytes" \
  --argjson file_count "$file_count" \
  '{schema: 1, content_bytes: $content_bytes, file_count: $file_count}'
