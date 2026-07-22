#!/usr/bin/env bash
set -euo pipefail

expected_environment="${1:-${MESH_RUNNER_ENVIRONMENT:-}}"
actual_environment="$(cat /etc/mesh-runner-environment)"

if [[ -n "$expected_environment" && "$actual_environment" != "$expected_environment" ]]; then
  echo "expected environment '$expected_environment', found '$actual_environment'" >&2
  exit 1
fi

for command_name in cargo cmake git glslc jq just lld node ninja npm pnpm python rustc sccache; do
  command -v "$command_name" >/dev/null || { echo "missing command: $command_name" >&2; exit 1; }
done

test -f /opt/mesh-llm/manifests/manifest-index.json
test -s /opt/mesh-llm/manifests/source-revision.txt

if [[ "$actual_environment" == "self-hosted" ]]; then
  test -x /home/runner/run.sh
  file /home/runner/bin/Runner.Listener | grep -q "$(case "$(uname -m)" in x86_64) echo 'x86-64' ;; aarch64) echo 'ARM aarch64' ;; *) exit 1 ;; esac)"
  if [[ "$(uname -m)" == "x86_64" ]]; then
    command -v nvcc >/dev/null
    test -f /usr/local/cuda/include/cublas_v2.h
    find /usr/local/cuda/targets/x86_64-linux/lib -name 'libcublas.so*' -print -quit | grep -q .
  fi
fi

python - <<'PY'
import langchain_openai
import litellm
import openai
print("python dependencies: ok")
PY

jq -n \
  --arg architecture "$(uname -m)" \
  --arg environment "$actual_environment" \
  --arg revision "$(cat /etc/mesh-llm-revision)" \
  --arg cargo "$(cargo --version)" \
  --arg node "$(node --version)" \
  --arg pnpm "$(pnpm --version)" \
  --arg python "$(python --version 2>&1)" \
  '{architecture: $architecture, environment: $environment, mesh_llm_revision: $revision, tools: {cargo: $cargo, node: $node, pnpm: $pnpm, python: $python}}'
