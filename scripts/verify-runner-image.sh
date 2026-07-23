#!/usr/bin/env bash
set -euo pipefail

expected_environment="${1:-${MESH_RUNNER_ENVIRONMENT:-}}"
expected_backend="${2:-${MESH_RUNNER_BACKEND:-}}"
actual_environment="$(cat /etc/mesh-runner-environment)"
actual_backend="$(cat /etc/mesh-runner-backend)"
verification_directory="$(mktemp -d)"
trap 'rm -rf "$verification_directory"' EXIT

if [[ -n "$expected_environment" && "$actual_environment" != "$expected_environment" ]]; then
  echo "expected environment '$expected_environment', found '$actual_environment'" >&2
  exit 1
fi

if [[ -n "$expected_backend" && "$actual_backend" != "$expected_backend" ]]; then
  echo "expected backend '$expected_backend', found '$actual_backend'" >&2
  exit 1
fi

for command_name in cargo cmake git jq just lld node ninja npm pnpm python rustc sccache; do
  command -v "$command_name" >/dev/null || { echo "missing command: $command_name" >&2; exit 1; }
done

test -f /opt/mesh-llm/manifests/manifest-index.json
test -s /opt/mesh-llm/manifests/source-revision.txt

if [[ "$actual_environment" == "self-hosted" ]]; then
  test -x /home/runner/run.sh
  file /home/runner/bin/Runner.Listener | grep -q "$(case "$(uname -m)" in x86_64) echo 'x86-64' ;; aarch64) echo 'ARM aarch64' ;; *) exit 1 ;; esac)"
fi

case "$actual_backend" in
  cpu) ;;
  vulkan)
    command -v glslc >/dev/null
    pkg-config --exists vulkan
    printf '%s\n' '#version 450' 'layout(local_size_x = 1) in;' 'void main() {}' \
      | glslc -fshader-stage=compute -o "$verification_directory/probe.spv" -
    ;;
  cuda)
    command -v nvcc >/dev/null
    cuda_series="$(cat /etc/mesh-runner-cuda-series)"
    nvcc --version | grep -Fq "release ${cuda_series/-/.}"
    test -f /usr/local/cuda/include/cublas_v2.h
    find /usr/local/cuda/targets -path '*/lib/libcublas.so*' -print -quit | grep -q .
    printf '%s\n' '__global__ void probe() {}' \
      | nvcc -x cu -c -o "$verification_directory/probe.o" -
    ;;
  rocm)
    command -v hipcc >/dev/null
    rocm_version="$(cat /etc/mesh-runner-rocm-version)"
    dpkg-query -W -f='${Version}\n' rocm-core | grep -q "^${rocm_version}"
    test -f /opt/rocm/include/hipblas/hipblas.h
    find /opt/rocm/lib -name 'librocblas.so*' -print -quit | grep -q .
    printf '%s\n' '#include <hip/hip_runtime.h>' '__global__ void probe() {}' \
      | hipcc -x hip -c --offload-arch=gfx1100 -o "$verification_directory/probe.o" -
    ;;
  *) echo "unsupported backend: $actual_backend" >&2; exit 1 ;;
esac

python - <<'PY'
import langchain_openai
import litellm
import openai
print("python dependencies: ok")
PY

jq -n \
  --arg architecture "$(uname -m)" \
  --arg environment "$actual_environment" \
  --arg backend "$actual_backend" \
  --arg revision "$(cat /etc/mesh-llm-revision)" \
  --arg cargo "$(cargo --version)" \
  --arg node "$(node --version)" \
  --arg pnpm "$(pnpm --version)" \
  --arg python "$(python --version 2>&1)" \
  '{architecture: $architecture, environment: $environment, backend: $backend, mesh_llm_revision: $revision, tools: {cargo: $cargo, node: $node, pnpm: $pnpm, python: $python}}'
