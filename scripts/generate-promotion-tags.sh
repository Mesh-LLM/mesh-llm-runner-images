#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 8 ]]; then
  cat >&2 <<'EOF'
usage: generate-promotion-tags.sh \
  versioned|latest IMAGE TAG_STEM COMPATIBILITY_TAG_STEM \
  TIMESTAMP MESH_REVISION RUNNER_IMAGES_REVISION CONTENT_DIGEST
EOF
  exit 2
fi

phase="$1"
image="$2"
tag_stem="$3"
compatibility_tag_stem="$4"
timestamp="$5"
mesh_revision="$6"
runner_images_revision="$7"
content_digest="$8"

[[ "$phase" == versioned || "$phase" == latest ]] || {
  echo "promotion phase must be 'versioned' or 'latest': $phase" >&2
  exit 1
}
[[ "$image" =~ ^ghcr\.io/[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+$ ]] || {
  echo "image must be an untagged lowercase ghcr.io repository" >&2
  exit 1
}
[[ "$tag_stem" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "invalid tag stem: $tag_stem" >&2
  exit 1
}
if [[ -n "$compatibility_tag_stem" ]]; then
  [[ "$compatibility_tag_stem" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "invalid compatibility tag stem: $compatibility_tag_stem" >&2
    exit 1
  }
  [[ "$compatibility_tag_stem" != "$tag_stem" ]] || {
    echo "compatibility tag stem duplicates the primary tag stem" >&2
    exit 1
  }
fi
[[ "$timestamp" =~ ^[0-9]{14}$ ]] || {
  echo "timestamp must contain 14 UTC date digits" >&2
  exit 1
}
[[ "$mesh_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "MeshLLM revision must be a full lowercase git SHA" >&2
  exit 1
}
[[ "$runner_images_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "runner-images revision must be a full lowercase git SHA" >&2
  exit 1
}
[[ "$content_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "content digest must be a lowercase sha256 OCI digest" >&2
  exit 1
}

emit_tag() {
  local mode="$1"
  local tag="$2"

  [[ "${#tag}" -le 128 ]] || {
    echo "generated OCI tag exceeds 128 characters: $tag" >&2
    exit 1
  }
  [[ "$tag" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
    echo "generated invalid OCI tag: $tag" >&2
    exit 1
  }
  printf '%s\n' "$mode" "${image}:${tag}"
}

stems=("$tag_stem")
if [[ -n "$compatibility_tag_stem" ]]; then
  stems+=("$compatibility_tag_stem")
fi

mesh_revision_short="${mesh_revision:0:12}"
content_digest_hex="${content_digest#sha256:}"
for stem in "${stems[@]}"; do
  case "$phase" in
    versioned)
      emit_tag --tag "${stem}-${timestamp}"
      # Compatibility alias: another runner-images revision may move this tag.
      emit_tag --tag "${stem}-sha-${mesh_revision_short}"
      # Immutable content identity: source revisions remain descriptor/label
      # metadata because provenance and resolved package inputs may vary.
      emit_tag --immutable-tag \
        "${stem}-digest-sha256-${content_digest_hex}"
      ;;
    latest)
      emit_tag --tag "${stem}-latest"
      ;;
  esac
done
