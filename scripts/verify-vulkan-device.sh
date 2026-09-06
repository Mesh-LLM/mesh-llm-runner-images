#!/usr/bin/env bash
set -euo pipefail

actual_backend="${MESH_RUNNER_BACKEND:-$(cat /etc/mesh-runner-backend 2>/dev/null || true)}"
[[ "$actual_backend" == vulkan || "$actual_backend" == cuda ]] || {
  echo "Vulkan device verification requires a vulkan or cuda NVIDIA runner image" >&2
  exit 1
}

for required_capability in compute utility graphics; do
  case ",${NVIDIA_DRIVER_CAPABILITIES:-}," in
    *,all,*|*,"$required_capability",*) ;;
    *)
      echo "Vulkan device verification requires NVIDIA driver capability: $required_capability" >&2
      exit 1
      ;;
  esac
done

command -v nvidia-smi >/dev/null || {
  echo "nvidia-smi is unavailable; NVIDIA Container Toolkit did not inject the utility capability" >&2
  exit 1
}
command -v vulkaninfo >/dev/null || {
  echo "vulkaninfo is unavailable from the runner image" >&2
  exit 1
}

verification_directory="$(mktemp -d)"
trap 'rm -rf "$verification_directory"' EXIT
summary="$verification_directory/vulkan-summary.txt"

nvidia-smi -L >/dev/null || {
  echo "nvidia-smi could not enumerate an NVIDIA device" >&2
  exit 1
}

if ! vulkaninfo --summary >"$summary" 2>&1; then
  cat "$summary" >&2
  echo "Vulkan loader could not enumerate an ICD-backed device" >&2
  exit 1
fi

grep -Fq 'Vulkan Instance Version:' "$summary" || {
  cat "$summary" >&2
  echo "vulkaninfo did not report a Vulkan loader instance" >&2
  exit 1
}
grep -Eq '^GPU[0-9]+:' "$summary" || {
  cat "$summary" >&2
  echo "vulkaninfo did not report a physical device" >&2
  exit 1
}
grep -Eiq 'vendorID[[:space:]]*=[[:space:]]*0x10de' "$summary" || {
  cat "$summary" >&2
  echo "vulkaninfo did not report an NVIDIA physical device" >&2
  exit 1
}

cat "$summary"
