#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
source_root="$temporary_directory/source"
mkdir -p "$source_root/crates/mesh-llm-ui" "$source_root/website"
printf '{}\n' > "$source_root/crates/mesh-llm-ui/package.json"
printf 'lockfileVersion: 9\n' > "$source_root/crates/mesh-llm-ui/pnpm-lock.yaml"
printf 'engine-strict=true\n' > "$source_root/crates/mesh-llm-ui/.npmrc"
printf 'packages: []\n' > "$source_root/pnpm-workspace.yaml"
printf 'shared-workspace-lockfile=true\n' > "$source_root/.npmrc"
printf '[workspace]\n' > "$source_root/Cargo.toml"
printf '{}\n' > "$source_root/website/package.json"

index_source() {
  local path hash
  while IFS= read -r path; do
    hash="$(shasum -a 256 "$source_root/$path" | awk '{print $1}')"
    jq -cn --arg path "$path" --arg sha256 "$hash" '{path: $path, sha256: $sha256}'
  done < <(cd "$source_root" && find . -type f ! -name dependency-index.json | sed 's|^./||' | sort) \
    | jq -s '{schema: 1, files: .}' > "$source_root/dependency-index.json"
}
prepare() {
  bash "$repository_root/scripts/prepare-ui-dependencies.sh" "$source_root" "$temporary_directory/$1"
}
expect_failure() {
  if prepare "$1" > "$temporary_directory/failure.log" 2>&1; then
    echo "expected UI manifest preparation to fail: $1" >&2
    exit 1
  fi
  test ! -e "$temporary_directory/$1"
}

index_source
prepare first
jq -e '.files | map(.path) == [".npmrc", "crates/mesh-llm-ui/.npmrc", "crates/mesh-llm-ui/package.json", "crates/mesh-llm-ui/pnpm-lock.yaml", "pnpm-workspace.yaml"]' \
  "$temporary_directory/first/dependency-index.json" >/dev/null
test ! -e "$temporary_directory/first/Cargo.toml"
test ! -e "$temporary_directory/first/website"
printf '[workspace]\nversion = "2"\n' > "$source_root/Cargo.toml"
index_source
prepare cargo-change
diff -r "$temporary_directory/first" "$temporary_directory/cargo-change"
printf 'engine-strict=false\n' > "$source_root/crates/mesh-llm-ui/.npmrc"
expect_failure mismatched-hash
index_source
prepare config-change
if cmp -s "$temporary_directory/first/dependency-index.json" "$temporary_directory/config-change/dependency-index.json"; then
  echo "UI configuration change did not change the dependency subset" >&2
  exit 1
fi
rm "$source_root/crates/mesh-llm-ui/pnpm-lock.yaml"
index_source
expect_failure missing-ui-lock
printf 'lockfileVersion: 9\n' > "$source_root/crates/mesh-llm-ui/pnpm-lock.yaml"
index_source
mv "$source_root/crates/mesh-llm-ui/package.json" "$temporary_directory/package.json"
ln -s "$temporary_directory/package.json" "$source_root/crates/mesh-llm-ui/package.json"
expect_failure symlink
echo "UI dependency subset tests passed"
