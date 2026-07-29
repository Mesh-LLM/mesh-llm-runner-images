#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
family_descriptor="$repository_root/config/runner-image-families.json"
matrix_generator="$repository_root/scripts/generate-workflow-matrices.sh"
runner_selector="$repository_root/scripts/select-runner-provider.sh"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

assert_selection() {
  local event_name="$1"
  local github_ref="$2"
  local depot_setting="$3"
  local expected_provider="$4"
  local expected_orchestration_runner="$5"
  local expected_amd64_runner="$6"
  local expected_arm64_runner="$7"
  local selection

  selection="$(bash "$runner_selector" "$event_name" "$github_ref" "$depot_setting")"
  jq -e \
    --arg provider "$expected_provider" \
    --arg github_ref "$github_ref" \
    --arg orchestration_runner "$expected_orchestration_runner" \
    --arg amd64_runner "$expected_amd64_runner" \
    --arg arm64_runner "$expected_arm64_runner" \
    '
      . == {
        provider: $provider,
        github_ref: $github_ref,
        orchestration_runner: $orchestration_runner,
        platform_runners: {
          amd64: $amd64_runner,
          arm64: $arm64_runner
        }
      }
    ' <<< "$selection" >/dev/null
}

assert_matrix() {
  local provider="$1"
  local expected_amd64_runner="$2"
  local expected_arm64_runner="$3"
  local matrices

  matrices="$(bash "$matrix_generator" "$family_descriptor" "$provider")"
  jq -e \
    --arg amd64_runner "$expected_amd64_runner" \
    --arg arm64_runner "$expected_arm64_runner" \
    '
      .family_matrix.include as $families
      | ($families | length) == 12
      and ([$families[].environment] | unique | sort) == ["public", "self-hosted"]
      and ([$families[].backend_id] | unique | sort) == [
        "cpu",
        "cuda12",
        "cuda13",
        "rocm70",
        "rocm72",
        "vulkan"
      ]
      and all(
        $families[];
        if .backend_name == "rocm" then
          .architectures == "amd64"
          and .platform_matrix.include == [{
            platform: "linux/amd64",
            platform_id: "amd64",
            runner: $amd64_runner
          }]
        else
          .architectures == "amd64,arm64"
          and .platform_matrix.include == [
            {
              platform: "linux/amd64",
              platform_id: "amd64",
              runner: $amd64_runner
            },
            {
              platform: "linux/arm64",
              platform_id: "arm64",
              runner: $arm64_runner
            }
          ]
        end
      )
      and (
        .promotion_matrix.include as $promotions
        | ($promotions | length) == 13
        and ([$promotions[] | select(.backend_id == "compatibility")] | length) == 1
        and ([$promotions[] | select(.compatibility_tag_stem != "")] | length) == 1
        and (
          [$promotions[] | select(.compatibility_tag_stem != "")][0]
          | .environment == "public"
          and .backend_id == "cpu"
          and .compatibility_tag_stem == "public"
        )
        and ([$promotions[].tag_stem] | sort) == [
          "public-cpu",
          "public-cuda12",
          "public-cuda13",
          "public-rocm70",
          "public-rocm72",
          "public-vulkan",
          "self-hosted",
          "self-hosted-cpu",
          "self-hosted-cuda12",
          "self-hosted-cuda13",
          "self-hosted-rocm70",
          "self-hosted-rocm72",
          "self-hosted-vulkan"
        ]
        and all($promotions[]; has("platform_matrix") | not)
      )
    ' <<< "$matrices" >/dev/null
}

# Pull requests never use Depot, even when the rollout variable is enabled.
assert_selection pull_request refs/pull/42/merge true \
  github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm
assert_selection pull_request refs/pull/42/merge false \
  github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm

# Trusted main events use Depot only for the exact opt-in value "true".
for event_name in push schedule workflow_dispatch; do
  assert_selection "$event_name" refs/heads/main true \
    depot depot-ubuntu-24.04-4 \
    depot-ubuntu-24.04-16 depot-ubuntu-24.04-arm-16
  assert_selection "$event_name" refs/heads/main false \
    github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm
  assert_selection "$event_name" refs/heads/main TRUE \
    github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm
  assert_selection "$event_name" refs/heads/main "" \
    github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm
  assert_selection "$event_name" refs/heads/feature/depot-test true \
    github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm
  assert_selection "$event_name" refs/tags/v1.2.3 true \
    github ubuntu-24.04 ubuntu-24.04 ubuntu-24.04-arm
done

assert_matrix github ubuntu-24.04 ubuntu-24.04-arm
assert_matrix depot depot-ubuntu-24.04-16 depot-ubuntu-24.04-arm-16
expect_failure bash "$runner_selector" issue_comment refs/heads/main true
expect_failure bash "$matrix_generator" "$family_descriptor" unknown

extra_key_descriptor="$temporary_directory/extra-key.json"
jq '.unexpected = true' "$family_descriptor" > "$extra_key_descriptor"
expect_failure bash "$matrix_generator" "$extra_key_descriptor" github

inconsistent_cuda_descriptor="$temporary_directory/inconsistent-cuda.json"
jq '.backends[] |= if .id == "cuda12" then .cuda_series = "13-1" else . end' \
  "$family_descriptor" > "$inconsistent_cuda_descriptor"
expect_failure bash "$matrix_generator" "$inconsistent_cuda_descriptor" github

duplicate_tag_descriptor="$temporary_directory/duplicate-tag.json"
jq '.indexes[0].tag_stem = "public"' \
  "$family_descriptor" > "$duplicate_tag_descriptor"
expect_failure bash "$matrix_generator" "$duplicate_tag_descriptor" github

workflow="$repository_root/.github/workflows/build-and-push.yml"
[[ "$(grep -c 'vars\.DEPOT_RUNNERS_ENABLED' "$workflow")" -eq 1 ]]
[[ "$(grep -F -c 'runs-on: ubuntu-24.04' "$workflow")" -eq 1 ]]
grep -Fq "runs-on: \${{ needs.policy.outputs.orchestration_runner }}" "$workflow"
grep -Fq "RUNNER_PROVIDER: \${{ needs.policy.outputs.runner_provider }}" "$workflow"
if grep -q 'runs-on: depot-ubuntu' "$workflow"; then
  echo "workflow bypasses the centralized runner rollout selector" >&2
  exit 1
fi

echo "runner selection and workflow matrix contracts passed"
