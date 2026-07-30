#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
family_descriptor="$repository_root/config/runner-image-families.json"
matrix_generator="$repository_root/scripts/generate-workflow-matrices.sh"
pr_planner="$repository_root/scripts/plan-pr-families.sh"
runner_selector="$repository_root/scripts/select-runner-provider.sh"
mode_selector="$repository_root/scripts/select-workflow-mode.sh"
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
  local matrices

  matrices="$(bash "$matrix_generator" "$family_descriptor")"
  jq -e \
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
        else
          .architectures == "amd64,arm64"
        end
        and (has("platform_matrix") | not)
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

assert_matrix
expect_failure bash "$runner_selector" issue_comment refs/heads/main true

extra_key_descriptor="$temporary_directory/extra-key.json"
jq '.unexpected = true' "$family_descriptor" > "$extra_key_descriptor"
expect_failure bash "$matrix_generator" "$extra_key_descriptor"

inconsistent_cuda_descriptor="$temporary_directory/inconsistent-cuda.json"
jq '.backends[] |= if .id == "cuda12" then .cuda_series = "13-1" else . end' \
  "$family_descriptor" > "$inconsistent_cuda_descriptor"
expect_failure bash "$matrix_generator" "$inconsistent_cuda_descriptor"

duplicate_tag_descriptor="$temporary_directory/duplicate-tag.json"
jq '.indexes[0].tag_stem = "public"' \
  "$family_descriptor" > "$duplicate_tag_descriptor"
expect_failure bash "$matrix_generator" "$duplicate_tag_descriptor"

expected_repository=Mesh-LLM/mesh-llm-runner-images
main_workflow="$expected_repository/.github/workflows/build-and-push.yml@refs/heads/main"
[[ "$(bash "$mode_selector" pull_request "$expected_repository" refs/pull/9/merge \
  "$expected_repository/.github/workflows/build-and-push.yml@refs/pull/9/merge" promote \
  | jq -r '.execution_mode')" == validate ]]
[[ "$(bash "$mode_selector" push "$expected_repository" refs/heads/main \
  "$main_workflow" validate | jq -r '.execution_mode')" == stage ]]
[[ "$(bash "$mode_selector" schedule "$expected_repository" refs/heads/main \
  "$main_workflow" validate | jq -r '.execution_mode')" == promote ]]
for requested_mode in validate stage promote; do
  [[ "$(bash "$mode_selector" workflow_dispatch "$expected_repository" refs/heads/main \
    "$main_workflow" "$requested_mode" | jq -r '.execution_mode')" == "$requested_mode" ]]
done
expect_failure bash "$mode_selector" workflow_dispatch "$expected_repository" \
  refs/heads/feature "$expected_repository/.github/workflows/build-and-push.yml@refs/heads/feature" \
  stage
expect_failure bash "$mode_selector" workflow_dispatch "$expected_repository" \
  refs/heads/feature "$expected_repository/.github/workflows/build-and-push.yml@refs/heads/feature" \
  promote
expect_failure bash "$mode_selector" workflow_dispatch another/repository \
  refs/heads/main "$main_workflow" validate

assert_pr_plan() {
  local changed_path="$1"
  local expected_count="$2"
  local expected_filter="$3"
  local changed_file_list="$temporary_directory/changed-files.txt"
  printf '%s\n' "$changed_path" > "$changed_file_list"
  plan="$(bash "$pr_planner" "$family_descriptor" "$changed_file_list")"
  [[ "$(jq '.family_matrix.include | length' <<< "$plan")" -eq "$expected_count" ]]
  jq -e "$expected_filter" <<< "$plan" >/dev/null
}

assert_pr_plan docs/OPERATIONS.md 1 \
  '.family_matrix.include == [{
    environment: "public",
    backend_id: "cpu",
    backend_name: "cpu",
    cuda_series: "none",
    rocm_version: "none",
    architectures: "amd64"
  }]'
assert_pr_plan scripts/install-rocm-toolchain.sh 5 \
  '([.family_matrix.include[] | select(.backend_id | startswith("rocm"))] | length) == 4'
assert_pr_plan profiles/public.yml 6 \
  'all(.family_matrix.include[]; .environment == "public")'
assert_pr_plan Dockerfile 12 '.selection.exhaustive == true'

workflow="$repository_root/.github/workflows/build-and-push.yml"
reusable_workflow="$repository_root/.github/workflows/stage-image-family.yml"
[[ "$(grep -c 'vars\.DEPOT_RUNNERS_ENABLED' "$workflow")" -eq 1 ]]
[[ "$(grep -F -c 'runs-on: ubuntu-24.04' "$workflow")" -eq 1 ]]
grep -Fq "runs-on: \${{ needs.policy.outputs.orchestration_runner }}" "$workflow"
if grep -q 'runs-on: depot-ubuntu' "$workflow"; then
  echo "workflow bypasses the centralized runner rollout selector" >&2
  exit 1
fi
grep -Fq 'default: validate' "$workflow"
if grep -Eq 'should_publish|inputs\.push' "$workflow"; then
  echo "workflow conflates candidate staging and alias promotion" >&2
  exit 1
fi
if grep -Eq 'platform_matrix:|orchestration_runner:' "$reusable_workflow"; then
  echo "reusable workflow accepts caller-controlled runner selection" >&2
  exit 1
fi
if grep -Eq 'runs-on:.*(inputs|matrix\.runner)' "$reusable_workflow"; then
  echo "caller-controlled input reaches reusable workflow runs-on" >&2
  exit 1
fi
[[ "$(grep -F -c "$main_workflow" "$reusable_workflow")" -ge 3 ]]
grep -Fq "github.repository == '$expected_repository'" "$reusable_workflow"
grep -Fq "github.ref == 'refs/heads/main'" "$reusable_workflow"
grep -Fq "vars.DEPOT_RUNNERS_ENABLED == 'true'" "$reusable_workflow"
grep -Fq "inputs.execution_mode != 'validate'" "$reusable_workflow"
if grep -Fq "mode=max,scope=\${{ inputs.environment }}" "$reusable_workflow"; then
  echo "reusable workflow unconditionally exports a maximal cache" >&2
  exit 1
fi
candidate_tag_pattern="candidate-\${GITHUB_RUN_ID}-\${GITHUB_RUN_ATTEMPT}"
workflow_candidate_tag_count="$(
  grep -F -c "$candidate_tag_pattern" "$workflow"
)"
reusable_candidate_tag_count="$(
  grep -F -c "$candidate_tag_pattern" "$reusable_workflow"
)"
candidate_tag_count="$(
  printf '%s\n' \
    "$((workflow_candidate_tag_count + reusable_candidate_tag_count))"
)"
[[ "$candidate_tag_count" -ge 2 ]]
grep -Fq "needs.prepare.outputs.execution_mode == 'promote'" "$workflow"
grep -Fq "scripts/reconcile-image-cohort.sh \"\$manifest\" target" "$workflow"
grep -Fq 'target retention window is 14 days' \
  "$repository_root/docs/OPERATIONS.md"
grep -Fq 'no main-branch ruleset or branch protection' \
  "$repository_root/docs/OPERATIONS.md"

echo "runner selection and workflow matrix contracts passed"
