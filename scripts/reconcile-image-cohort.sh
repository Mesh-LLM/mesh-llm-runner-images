#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: reconcile-image-cohort.sh MANIFEST target|previous" >&2
  exit 2
fi

manifest="$1"
direction="$2"
[[ -f "$manifest" ]] || {
  echo "cohort manifest does not exist: $manifest" >&2
  exit 1
}
[[ "$direction" == target || "$direction" == previous ]] || {
  echo "cohort direction must be target or previous: $direction" >&2
  exit 1
}

if ! jq -e '
  def exact_keys($expected): (keys | sort) == ($expected | sort);
  def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
  . as $root
  | type == "object"
  and exact_keys([
    "entries",
    "image",
    "mesh_revision",
    "runner_images_revision",
    "schema",
    "timestamp",
    "type"
  ])
  and .schema == 1
  and .type == "mesh-llm-runner-image-latest-cohort"
  and (.image | type == "string" and test("^ghcr\\.io/[a-z0-9._-]+(/[a-z0-9._-]+)+$"))
  and (.mesh_revision | type == "string" and test("^[0-9a-f]{40}$"))
  and (.runner_images_revision | type == "string" and test("^[0-9a-f]{40}$"))
  and (.timestamp | type == "string" and test("^[0-9]{14}$"))
  and (.entries | type == "array" and length > 0)
  and all(
    .entries[];
    exact_keys(["artifact", "previous_digest", "tag", "target_digest"])
    and (.artifact | type == "string" and test("^candidate-index-[a-z0-9-]+$"))
    and (.tag | type == "string" and test("^ghcr\\.io/[a-z0-9._-]+(/[a-z0-9._-]+)+:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"))
    and (.tag | startswith($root.image + ":"))
    and (.target_digest | digest)
    and (.previous_digest == null or (.previous_digest | digest))
  )
  and ([.entries[].tag] | length == (unique | length))
' "$manifest" >/dev/null; then
  echo "latest cohort manifest failed validation: $manifest" >&2
  exit 1
fi

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

image="$(jq -er '.image' "$manifest")"
entries_file="$(mktemp)"
trap 'rm -f "$entries_file"' EXIT
jq -cr '.entries[]' "$manifest" > "$entries_file"

# Resolve every source before changing a tag. Previous entries that did not
# exist are intentionally skipped during rollback because deleting a GHCR
# package version could also delete promoted references to the same digest.
while IFS= read -r entry; do
  if [[ "$direction" == target ]]; then
    digest="$(jq -er '.target_digest' <<< "$entry")"
  else
    digest="$(jq -er '.previous_digest // empty' <<< "$entry")"
    [[ -n "$digest" ]] || continue
  fi
  manifest_json="$(
    "$docker_binary" buildx imagetools inspect "${image}@${digest}" \
      --format '{{json .Manifest}}'
  )"
  resolved_digest="$(
    jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
      <<< "$manifest_json"
  )"
  [[ "$resolved_digest" == "$digest" ]] || {
    echo "cohort source resolved to $resolved_digest, expected $digest" >&2
    exit 1
  }
done < "$entries_file"

while IFS= read -r entry; do
  tag="$(jq -er '.tag' <<< "$entry")"
  if [[ "$direction" == target ]]; then
    digest="$(jq -er '.target_digest' <<< "$entry")"
  else
    digest="$(jq -er '.previous_digest // empty' <<< "$entry")"
    if [[ -z "$digest" ]]; then
      echo "rollback leaves previously absent tag unchanged: $tag" >&2
      continue
    fi
  fi
  "$docker_binary" buildx imagetools create \
    --tag "$tag" \
    "${image}@${digest}"
  manifest_json="$(
    "$docker_binary" buildx imagetools inspect "$tag" \
      --format '{{json .Manifest}}'
  )"
  resolved_digest="$(
    jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' \
      <<< "$manifest_json"
  )"
  [[ "$resolved_digest" == "$digest" ]] || {
    echo "cohort tag $tag resolved to $resolved_digest, expected $digest" >&2
    exit 1
  }
  echo "reconciled $tag -> $digest"
done < "$entries_file"
