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

extract_job_block() {
  local workflow_file="$1"
  local job_name="$2"
  local output_file="$3"
  awk -v header="  ${job_name}:" '
    $0 == header { printing = 1 }
    printing && $0 ~ /^  [[:alnum:]_]+:$/ && $0 != header { exit }
    printing { print }
  ' "$workflow_file" > "$output_file"
  [[ -s "$output_file" ]]
}

normalize_runs_on_expression() {
  local job_file="$1"

  awk '
    /^    runs-on: >-$/ { printing = 1; next }
    printing && /^    [[:alnum:]_-]+:/ { exit }
    printing { print }
  ' "$job_file" |
    tr '\n\t' '  ' |
    sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

extract_markdown_section() {
  local document_file="$1"
  local heading="$2"
  local output_file="$3"

  awk -v heading="$heading" '
    $0 == heading { printing = 1 }
    printing && /^## / && $0 != heading { exit }
    printing { print }
  ' "$document_file" > "$output_file"
  [[ -s "$output_file" ]]
}

extract_step_block() {
  local job_file="$1"
  local step_name="$2"
  local output_file="$3"
  awk -v header="      - name: ${step_name}" '
    $0 == header { printing = 1 }
    printing && /^      - name:/ && $0 != header { exit }
    printing { print }
  ' "$job_file" > "$output_file"
  [[ -s "$output_file" ]]
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
policy_job="$temporary_directory/policy-job.yml"
validate_families_job="$temporary_directory/validate-families-job.yml"
stage_families_job="$temporary_directory/stage-families-job.yml"
build_platform_job="$temporary_directory/build-platform-job.yml"
assemble_family_index_job="$temporary_directory/assemble-family-index-job.yml"
depot_config_step="$temporary_directory/depot-config-step.yml"
trust_boundary_step="$temporary_directory/trust-boundary-step.yml"
depot_build_step="$temporary_directory/depot-build-step.yml"
staged_digest_verification_step="$temporary_directory/staged-digest-verification-step.yml"
extract_job_block "$workflow" policy "$policy_job"
extract_job_block "$workflow" validate_families "$validate_families_job"
extract_job_block "$workflow" stage_families "$stage_families_job"
extract_job_block "$reusable_workflow" build_platform "$build_platform_job"
extract_job_block "$reusable_workflow" assemble_family_index "$assemble_family_index_job"
extract_step_block "$policy_job" \
  'Validate Depot remote builder configuration' "$depot_config_step"
extract_step_block "$build_platform_job" \
  'Enforce reusable workflow trust boundary' "$trust_boundary_step"
extract_step_block "$build_platform_job" \
  'Build platform image once' "$depot_build_step"
extract_step_block "$build_platform_job" \
  'Verify exact staged platform digest' "$staged_digest_verification_step"
[[ "$(grep -c 'vars\.DEPOT_RUNNERS_ENABLED' "$workflow")" -eq 1 ]]
[[ "$(grep -F -c 'runs-on: ubuntu-24.04' "$workflow")" -eq 1 ]]
grep -Fq "runs-on: \${{ needs.policy.outputs.orchestration_runner }}" "$workflow"
if grep -q 'runs-on: depot-ubuntu' "$workflow"; then
  echo "workflow bypasses the centralized runner rollout selector" >&2
  exit 1
fi
grep -Fq 'default: validate' "$workflow"
grep -Fxq '      DEPOT_PROJECT_ID: mzm95zcv7p' "$policy_job"
grep -Fq "[[ \"\$DEPOT_PROJECT_ID\" == mzm95zcv7p ]]" "$depot_config_step"
grep -Fq 'unexpected checked-in Depot project ID' "$depot_config_step"
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
[[ "$(grep -F -c "$main_workflow" "$reusable_workflow")" -ge 2 ]]
grep -Fq "github.repository == '$expected_repository'" "$reusable_workflow"
grep -Fq "github.ref == 'refs/heads/main'" "$reusable_workflow"
grep -Fq "vars.DEPOT_RUNNERS_ENABLED == 'true'" "$reusable_workflow"
grep -Fq "inputs.execution_mode != 'validate'" "$reusable_workflow"
build_platform_runs_on="$(normalize_runs_on_expression "$build_platform_job")"
assemble_family_index_runs_on="$(normalize_runs_on_expression "$assemble_family_index_job")"
if [[ "$build_platform_runs_on" != *"matrix.platform_id == 'amd64' && 'depot-ubuntu-24.04-16' || 'depot-ubuntu-24.04-arm-16'"* ]]; then
  echo "platform runner expression does not map AMD64 and Arm64 to the native Depot labels" >&2
  exit 1
fi
if [[ "$build_platform_runs_on" == *'depot-ubuntu-24.04-4'* ]]; then
  echo "platform builds use the smaller Depot orchestration runner" >&2
  exit 1
fi
if [[ "$assemble_family_index_runs_on" != *"&& 'depot-ubuntu-24.04-4' || 'ubuntu-24.04'"* ]]; then
  echo "assembly runner expression does not select the smaller Depot runner" >&2
  exit 1
fi
if [[ "$assemble_family_index_runs_on" == *'depot-ubuntu-24.04-16'* || "$assemble_family_index_runs_on" == *'depot-ubuntu-24.04-arm-16'* ]]; then
  echo "assembly uses a native-build runner instead of the smaller Depot runner" >&2
  exit 1
fi
grep -Fxq '      DEPOT_PROJECT_ID: mzm95zcv7p' "$build_platform_job"
grep -Fq "[[ \"\$DEPOT_PROJECT_ID\" == mzm95zcv7p ]]" "$trust_boundary_step"
grep -Fq 'depot/setup-action@15c09a5f77a0840ad4bce955686522a257853461' \
  "$build_platform_job"
grep -Fq 'depot/build-push-action@98e78adca7817480b8185f474a400b451d74e287' \
  "$depot_build_step"
grep -Fq "project: \${{ env.DEPOT_PROJECT_ID }}" "$depot_build_step"
if grep -Eq 'docker/build-push-action|type=gha' "$depot_build_step"; then
  echo "reusable workflow bypasses Depot's persistent project cache" >&2
  exit 1
fi
grep -Fq 'push-by-digest=true,name-canonical=true,push=true' \
  "$depot_build_step"
grep -Fq "provenance: \${{ inputs.execution_mode != 'validate' && 'mode=max' || 'false' }}" \
  "$depot_build_step"
grep -Fq "sbom: \${{ inputs.execution_mode != 'validate' }}" \
  "$depot_build_step"
grep -Fq "depot build \\" "$staged_digest_verification_step"
grep -Fq -- "--project \"\$DEPOT_PROJECT_ID\"" \
  "$staged_digest_verification_step"
if grep -Fq 'docker buildx build' "$staged_digest_verification_step"; then
  echo "staged digest verification downloads image layers to the GitHub runner" >&2
  exit 1
fi
grep -Fq 'Upload Depot build record' "$build_platform_job"
grep -Fxq '      contents: read' "$validate_families_job"
grep -Fxq '      id-token: write' "$validate_families_job"
grep -Fxq '      contents: read' "$stage_families_job"
grep -Fxq '      id-token: write' "$stage_families_job"
grep -Fxq '      packages: write' "$stage_families_job"
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
operations_audit="$temporary_directory/live-enablement-audit.md"
extract_markdown_section \
  "$repository_root/docs/OPERATIONS.md" \
  '### Live enablement and audit' \
  "$operations_audit"
grep -Fxq '### Live enablement and audit' "$operations_audit"
grep -Fq "\`DEPOT_RUNNERS_ENABLED=true\`" "$operations_audit"
grep -Fq "\`Default\` Depot runner group" "$operations_audit"
grep -Fq 'shared by multiple organization repositories' "$operations_audit"
grep -Fq 'per-run selection gate' "$operations_audit"
grep -Fq 'pull request requirement' "$operations_audit"
grep -Fq 'one fresh approval after the most recent push' "$operations_audit"
grep -Fq 'resolved conversations' "$operations_audit"
grep -Fq 'administrator enforcement' "$operations_audit"
grep -Fq "\`build-and-push.yml@refs/heads/main\`" "$operations_audit"
grep -Fq 'Pull requests, tags, and feature-branch workflow dispatches' "$operations_audit"
grep -Fq 'use GitHub-hosted runners' "$operations_audit"
grep -Fq "\`DEPOT_RUNNERS_ENABLED=false\` or remove the variable" "$operations_audit"

echo "runner selection and workflow matrix contracts passed"
