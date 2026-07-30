#!/usr/bin/env bash
set -euo pipefail

: "${MOCK_DOCKER_LOG:?MOCK_DOCKER_LOG is required}"
: "${MOCK_DOCKER_SOURCE_DIGEST:?MOCK_DOCKER_SOURCE_DIGEST is required}"

{
  printf '%q ' "$@"
  printf '\n'
} >> "$MOCK_DOCKER_LOG"

if [[ "${1:-}" == buildx && "${2:-}" == imagetools && "${3:-}" == inspect ]]; then
  reference="${4:-}"
  if [[ -n "${MOCK_DOCKER_MISSING_TAG_PATTERN:-}" \
    && "$reference" == *"$MOCK_DOCKER_MISSING_TAG_PATTERN"* \
    && ! "$(cat "$MOCK_DOCKER_LOG")" =~ "buildx imagetools create" ]]; then
    echo "manifest unknown: $reference not found" >&2
    exit 1
  fi
  if [[ "${5:-}" == --raw ]]; then
    : "${MOCK_DOCKER_RAW_MANIFEST_FILE:?MOCK_DOCKER_RAW_MANIFEST_FILE is required}"
    cat "$MOCK_DOCKER_RAW_MANIFEST_FILE"
  else
    if [[ "$reference" == *@sha256:* ]]; then
      digest="$MOCK_DOCKER_SOURCE_DIGEST"
    else
      digest="${MOCK_DOCKER_TAG_DIGEST:-$MOCK_DOCKER_SOURCE_DIGEST}"
    fi
    jq -cn --arg digest "$digest" '{digest: $digest}'
  fi
elif [[ "${1:-}" == buildx && "${2:-}" == imagetools && "${3:-}" == create ]]; then
  exit "${MOCK_DOCKER_CREATE_EXIT:-0}"
else
  echo "unexpected mock docker invocation: $*" >&2
  exit 64
fi
