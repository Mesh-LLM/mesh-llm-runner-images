#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verifier="$repository_root/scripts/verify-vulkan-device.sh"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

expect_failure() {
  local expected_message="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected command to fail: $*"
  fi
  grep -Fq "$expected_message" <<< "$output" \
    || fail "expected failure message '$expected_message', got: $output"
}

mock_bin="$temporary_directory/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/nvidia-smi" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == -L ]]
printf '%s\n' 'GPU 0: NVIDIA Test GPU (UUID: GPU-test)'
MOCK

cat > "$mock_bin/vulkaninfo" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == --summary ]]
cat <<'OUTPUT'
Vulkan Instance Version: 1.3.280

Devices:
========
GPU0:
    vendorID          = 0x10de
    deviceName        = NVIDIA Test GPU
OUTPUT
MOCK

chmod 0755 "$mock_bin/nvidia-smi" "$mock_bin/vulkaninfo"

verification_output="$(
  PATH="$mock_bin:$PATH" \
    MESH_RUNNER_BACKEND=vulkan \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics \
    bash "$verifier"
)"
grep -Fq 'deviceName        = NVIDIA Test GPU' <<< "$verification_output"

PATH="$mock_bin:$PATH" \
  MESH_RUNNER_BACKEND=cuda \
  NVIDIA_DRIVER_CAPABILITIES=all \
  bash "$verifier" >/dev/null

expect_failure \
  'Vulkan device verification requires NVIDIA driver capability: graphics' \
  env PATH="$mock_bin:$PATH" MESH_RUNNER_BACKEND=vulkan \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility bash "$verifier"

cat > "$mock_bin/vulkaninfo" <<'MOCK'
#!/usr/bin/env bash
[[ "${1:-}" == --summary ]]
cat <<'OUTPUT'
Vulkan Instance Version: 1.3.280

Devices:
========
GPU0:
    vendorID          = 0x1002
    deviceName        = AMD Test GPU
OUTPUT
MOCK
chmod 0755 "$mock_bin/vulkaninfo"

expect_failure \
  'vulkaninfo did not report an NVIDIA physical device' \
  env PATH="$mock_bin:$PATH" MESH_RUNNER_BACKEND=vulkan \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics bash "$verifier"

vulkan_packages="$(
  bash "$repository_root/scripts/profile-packages.sh" \
    "$repository_root/profiles/backends/vulkan.yml"
)"
grep -Fxq vulkan-tools <<< "$vulkan_packages"

cuda_packages="$(
  bash "$repository_root/scripts/profile-packages.sh" \
    "$repository_root/profiles/backends/cuda.yml"
)"
grep -Fxq libvulkan1 <<< "$cuda_packages"
grep -Fxq vulkan-tools <<< "$cuda_packages"

[[ "$(grep -Fc 'NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics' \
  "$repository_root/Dockerfile")" -eq 2 ]]

echo "Vulkan runner image and live device verification contract passed"
