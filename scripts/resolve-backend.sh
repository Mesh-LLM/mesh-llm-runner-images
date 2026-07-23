#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: resolve-backend.sh BACKEND_ID" >&2
  exit 2
fi

case "$1" in
  cpu|vulkan)
    printf 'name=%s\n' "$1"
    ;;
  cuda12)
    printf 'name=cuda\ncuda_series=%s\n' "${CUDA_12_SERIES:?CUDA_12_SERIES is required}"
    ;;
  cuda13)
    printf 'name=cuda\ncuda_series=%s\n' "${CUDA_13_SERIES:?CUDA_13_SERIES is required}"
    ;;
  rocm70)
    printf 'name=rocm\nrocm_version=%s\n' "${ROCM_70_VERSION:?ROCM_70_VERSION is required}"
    ;;
  rocm72)
    printf 'name=rocm\nrocm_version=%s\n' "${ROCM_72_VERSION:?ROCM_72_VERSION is required}"
    ;;
  *)
    echo "unsupported backend id: $1" >&2
    exit 1
    ;;
esac
