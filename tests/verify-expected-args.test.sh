#!/usr/bin/env bash
set -euo pipefail

# Regression guard for the class of bug fixed alongside this test:
# Dockerfile.verify declared "ARG EXPECTED_PLAYWRIGHT_VERSION=none" and
# nothing ever passed a --build-arg for it, so every backend (including
# web, where the image genuinely bakes a Playwright version) silently
# compared "none" against itself. The staged web image failed real
# verification with "expected Playwright version 'none', found '1.62.1'"
# the first time Dockerfile.verify's stage-mode assertion path actually
# ran, post-merge -- invisible on the PR because PR CI calls
# verify-runner-image directly (execution_mode=validate), bypassing
# Dockerfile.verify's ARG-driven form entirely.
#
# This asserts the two declarations agree: every plain (unconditionally
# wired) EXPECTED_* ARG in Dockerfile.verify has a matching --build-arg in
# stage-image-family.yml, the only caller that exercises Dockerfile.verify.
# A backend-scoped ARG that's resolved internally (like
# EXPECTED_PLAYWRIGHT_VERSION after this fix) is deliberately not one of
# these -- it has no caller-supplied value to go missing.

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile_verify="$repository_root/Dockerfile.verify"
stage_workflow="$repository_root/.github/workflows/stage-image-family.yml"

declared_args="$(
  grep -oE '^ARG (EXPECTED_[A-Z_]+|VERIFIER_REVISION)' "$dockerfile_verify" |
    awk '{print $2}' |
    sort -u
)"
[[ -n "$declared_args" ]]

missing=0
while IFS= read -r arg_name; do
  [[ -n "$arg_name" ]] || continue
  if ! grep -Fq -- "--build-arg \"${arg_name}=" "$stage_workflow"; then
    echo "Dockerfile.verify declares ARG ${arg_name} but stage-image-family.yml never passes --build-arg \"${arg_name}=...\"" >&2
    missing=1
  fi
done <<< "$declared_args"

if [[ "$missing" -ne 0 ]]; then
  exit 1
fi

echo "Dockerfile.verify ARG EXPECTED_* / stage-image-family.yml --build-arg contract passed"
