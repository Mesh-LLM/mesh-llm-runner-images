#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
umask 022

usage() {
  echo "usage: collect-manifests.sh --source PATH --output PATH --profile public|self-hosted" >&2
  exit 2
}

source_repository=
output_directory=
profile=

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_repository="${2:-}"; shift 2 ;;
    --output) output_directory="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$source_repository" && -n "$output_directory" && -n "$profile" ]] || usage
[[ "$profile" == public || "$profile" == self-hosted ]] || usage

for command_name in cargo git jq; do
  command -v "$command_name" >/dev/null || {
    echo "missing required command: $command_name" >&2
    exit 1
  }
done

source_repository="$(cd "$source_repository" && pwd -P)"
[[ -e "$source_repository/.git" && -f "$source_repository/Cargo.toml" ]] || {
  echo "not a MeshLLM checkout: $source_repository" >&2
  exit 1
}

output_parent="$(cd "$(dirname "$output_directory")" && pwd -P)"
output_directory="$output_parent/$(basename "$output_directory")"
case "$output_directory" in
  /|"$HOME"|"$source_repository")
    echo "refusing unsafe output directory: $output_directory" >&2
    exit 1
    ;;
esac
rm -rf "$output_directory"
dependency_directory="$output_directory/dependencies"
mkdir -p "$dependency_directory"

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
metadata_file="$temporary_directory/cargo-metadata.json"
manifest_paths="$temporary_directory/manifest-paths.txt"
target_paths="$temporary_directory/target-paths.tsv"
tracked_paths="$temporary_directory/tracked-paths"
inventory_file="$temporary_directory/inventory.tsv"
json_entries="$temporary_directory/entries.jsonl"
dependency_inventory="$temporary_directory/dependencies.txt"
dependency_entries="$temporary_directory/dependencies.jsonl"
: > "$inventory_file"
: > "$json_entries"
: > "$dependency_inventory"
: > "$dependency_entries"

(cd "$source_repository" && cargo metadata --no-deps --format-version 1) > "$metadata_file"
# Materialize discovery before consuming it: process-substitution failures do
# not propagate through a while loop and must not produce a partial index.
jq -r '.packages[].manifest_path' "$metadata_file" > "$manifest_paths"
jq -r '
  .packages[].targets[]
  | [
      .src_path,
      (if any(.kind[]; . == "bin" or . == "custom-build" or . == "example" or . == "test")
       then "main" else "lib" end)
    ]
  | @tsv
' "$metadata_file" > "$target_paths"
git -C "$source_repository" ls-files -z > "$tracked_paths"

relative_path() {
  local absolute_path="$1"
  case "$absolute_path" in
    "$source_repository"/*) printf '%s\n' "${absolute_path#"$source_repository"/}" ;;
    *) echo "path is outside source repository: $absolute_path" >&2; exit 1 ;;
  esac
}

copy_manifest() {
  local ecosystem="$1"
  local relative="$2"
  [[ -f "$source_repository/$relative" ]] || return 0
  mkdir -p "$dependency_directory/$(dirname "$relative")"
  cp "$source_repository/$relative" "$dependency_directory/$relative"
  chmod 0644 "$dependency_directory/$relative"
  printf '%s\t%s\n' "$ecosystem" "$relative" >> "$inventory_file"
  printf '%s\n' "$relative" >> "$dependency_inventory"
}

for root_file in Cargo.toml Cargo.lock rust-toolchain rust-toolchain.toml; do
  copy_manifest rust "$root_file"
done
copy_manifest configuration .cargo/config.toml

while IFS= read -r manifest_path; do
  relative="$(relative_path "$manifest_path")"
  copy_manifest rust "$relative"
done < "$manifest_paths"

while IFS=$'\t' read -r target_path target_type; do
  relative="$(relative_path "$target_path")"
  destination="$dependency_directory/$relative"
  mkdir -p "$(dirname "$destination")"
  if [[ "$target_type" == main ]]; then
    printf 'fn main() {}\n' > "$destination"
  else
    printf '#![allow(dead_code)]\n' > "$destination"
  fi
  printf '%s\n' "$relative" >> "$dependency_inventory"
done < "$target_paths"

while IFS= read -r -d '' relative; do
  filename="$(basename "$relative")"
  case "$filename" in
    package.json|package-lock.json|pnpm-lock.yaml|yarn.lock) ecosystem=node ;;
    .npmrc|pnpm-workspace.yaml) ecosystem=configuration ;;
    go.mod|go.sum) ecosystem=go ;;
    Pipfile|Pipfile.lock|poetry.lock|pyproject.toml|requirements*.txt|uv.lock) ecosystem=python ;;
    *) continue ;;
  esac
  copy_manifest "$ecosystem" "$relative"
done < "$tracked_paths"

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

sort -u "$inventory_file" | while IFS=$'\t' read -r ecosystem relative; do
  hash="$(sha256_file "$dependency_directory/$relative")"
  jq -cn \
    --arg ecosystem "$ecosystem" \
    --arg path "$relative" \
    --arg sha256 "$hash" \
    '{ecosystem: $ecosystem, path: $path, sha256: $sha256}' >> "$json_entries"
done

# The dependency layer is keyed only by files needed to resolve packages.
# Source revisions and runner profiles belong to the separate audit files.
sort -u "$dependency_inventory" | while IFS= read -r relative; do
  hash="$(sha256_file "$dependency_directory/$relative")"
  jq -cn \
    --arg path "$relative" \
    --arg sha256 "$hash" \
    '{path: $path, sha256: $sha256}' >> "$dependency_entries"
done
jq -s '{schema: 1, files: .}' "$dependency_entries" \
  > "$dependency_directory/dependency-index.json"

revision="$(git -C "$source_repository" rev-parse HEAD)"
jq -s \
  --arg profile "$profile" \
  --arg source_revision "$revision" \
  '{profile: $profile, source_revision: $source_revision, manifests: .}' \
  "$json_entries" > "$output_directory/manifest-index.json"
printf '%s\n' "$revision" > "$output_directory/source-revision.txt"
printf '%s\n' "$profile" > "$output_directory/profile.txt"

manifest_count="$(jq '.manifests | length' "$output_directory/manifest-index.json")"
echo "collected $manifest_count manifests for $profile from $revision"
