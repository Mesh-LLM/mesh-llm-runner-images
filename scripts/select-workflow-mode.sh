#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  cat >&2 <<'EOF'
usage: select-workflow-mode.sh \
  EVENT_NAME REPOSITORY GITHUB_REF WORKFLOW_REF REQUESTED_MODE
EOF
  exit 2
fi

event_name="$1"
repository="$2"
github_ref="$3"
workflow_ref="$4"
requested_mode="$5"
expected_repository=Mesh-LLM/mesh-llm-runner-images
expected_main_workflow="$expected_repository/.github/workflows/build-and-push.yml@refs/heads/main"

[[ "$repository" == "$expected_repository" ]] || {
  echo "workflow may run only in $expected_repository: $repository" >&2
  exit 1
}

case "$event_name" in
  pull_request)
    execution_mode=validate
    ;;
  push)
    execution_mode=stage
    ;;
  schedule)
    execution_mode=promote
    ;;
  workflow_dispatch)
    execution_mode="$requested_mode"
    ;;
  *)
    echo "unsupported workflow event: $event_name" >&2
    exit 1
    ;;
esac

case "$execution_mode" in
  validate) ;;
  stage|promote)
    [[ "$github_ref" == refs/heads/main ]] || {
      echo "$execution_mode requires refs/heads/main: $github_ref" >&2
      exit 1
    }
    [[ "$workflow_ref" == "$expected_main_workflow" ]] || {
      echo "$execution_mode requires the default-branch workflow: $workflow_ref" >&2
      exit 1
    }
    ;;
  *)
    echo "execution mode must be validate, stage, or promote: $execution_mode" >&2
    exit 1
    ;;
esac

if [[ "$event_name" == push && "$execution_mode" != stage ]]; then
  echo "main pushes may stage candidates but cannot promote aliases" >&2
  exit 1
fi
if [[ "$event_name" == schedule && "$execution_mode" != promote ]]; then
  echo "scheduled publication must use promote mode" >&2
  exit 1
fi

jq -cn \
  --arg execution_mode "$execution_mode" \
  '{
    execution_mode: $execution_mode,
    should_stage: ($execution_mode == "stage" or $execution_mode == "promote"),
    should_promote: ($execution_mode == "promote")
  }'
