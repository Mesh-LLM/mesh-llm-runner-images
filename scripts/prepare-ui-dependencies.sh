#!/usr/bin/env bash
set -euo pipefail

source_root="${1:?usage: prepare-ui-dependencies.sh SOURCE OUTPUT}"
output_root="${2:?usage: prepare-ui-dependencies.sh SOURCE OUTPUT}"
[[ ! -e "$output_root" && ! -L "$output_root" ]] || {
  echo "UI dependency output already exists: $output_root" >&2
  exit 1
}
index="$source_root/dependency-index.json"
jq -e '
  .schema == 1 and (.files | type == "array")
  and all(.files[]; (.path | type == "string") and (.sha256 | test("^[0-9a-f]{64}$")))
  and ([.files[].path] | length == (unique | length))
' "$index" >/dev/null

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
payload="$temporary_directory/payload"
mkdir -p "$payload"
# Retain root configuration and the UI package's complete package-manager
# configuration. Cargo, Python, website and source-revision inputs stay out of
# this dependency layer; the final image copies audit metadata separately.
jq '
  {schema: 1, files: [.files[] | select(.path | test("^(crates/mesh-llm-ui/)?(package\\.json|package-lock\\.json|pnpm-lock\\.yaml|pnpm-workspace\\.yaml|yarn\\.lock|\\.npmrc)$"))] | sort_by(.path)}
' "$index" > "$payload/dependency-index.json"
jq -e '
  any(.files[]; .path == "crates/mesh-llm-ui/package.json")
  and any(.files[]; .path == "crates/mesh-llm-ui/pnpm-lock.yaml")
' "$payload/dependency-index.json" >/dev/null
rows="$(jq -r '.files[] | [.path, .sha256] | @tsv' "$payload/dependency-index.json")"
while IFS=$'\t' read -r relative expected_sha; do
  source_path="$source_root/$relative"
  [[ -f "$source_path" && ! -L "$source_path" ]] || {
    echo "UI dependency must be a regular file: $relative" >&2
    exit 1
  }
  # Each accepted nested path has only these two parent components.
  if [[ "$relative" == crates/* ]]; then
    [[ ! -L "$source_root/crates" && ! -L "$source_root/crates/mesh-llm-ui" ]] || {
      echo "UI dependency directories must not be symlinks" >&2
      exit 1
    }
  fi
  actual_sha="$(sha256sum "$source_path" | awk '{print $1}')"
  [[ "$actual_sha" == "$expected_sha" ]] || { echo "UI dependency checksum mismatch: $relative" >&2; exit 1; }
  mkdir -p "$payload/$(dirname "$relative")"
  cp "$source_path" "$payload/$relative"
  chmod 0644 "$payload/$relative"
done <<< "$rows"
mkdir -p "$(dirname "$output_root")"
mv "$payload" "$output_root"
