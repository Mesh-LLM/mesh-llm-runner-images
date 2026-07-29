#!/usr/bin/env bash
set -euo pipefail

event_name="${1:?usage: select-runner-provider.sh EVENT_NAME GITHUB_REF [DEPOT_RUNNERS_ENABLED]}"
github_ref="${2:?usage: select-runner-provider.sh EVENT_NAME GITHUB_REF [DEPOT_RUNNERS_ENABLED]}"
depot_runners_enabled="${3:-}"

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}

case "$event_name" in
  pull_request)
    provider=github
    ;;
  push|schedule|workflow_dispatch)
    if [[ "$github_ref" == refs/heads/main && "$depot_runners_enabled" == true ]]; then
      provider=depot
    else
      provider=github
    fi
    ;;
  *)
    echo "unsupported workflow event: $event_name" >&2
    exit 1
    ;;
esac

case "$provider" in
  github)
    orchestration_runner=ubuntu-24.04
    amd64_runner=ubuntu-24.04
    arm64_runner=ubuntu-24.04-arm
    ;;
  depot)
    orchestration_runner=depot-ubuntu-24.04-4
    amd64_runner=depot-ubuntu-24.04-16
    arm64_runner=depot-ubuntu-24.04-arm-16
    ;;
esac

jq -cn \
  --arg provider "$provider" \
  --arg github_ref "$github_ref" \
  --arg orchestration_runner "$orchestration_runner" \
  --arg amd64_runner "$amd64_runner" \
  --arg arm64_runner "$arm64_runner" \
  '{
    provider: $provider,
    github_ref: $github_ref,
    orchestration_runner: $orchestration_runner,
    platform_runners: {
      amd64: $amd64_runner,
      arm64: $arm64_runner
    }
  }'
