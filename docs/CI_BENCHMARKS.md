# CI benchmarks

## Pre-Depot baseline

The migration baseline was captured on 2026-07-29 from completed runs of the
original two-build-wave workflow. Wall time is measured from the GitHub run's
`createdAt` to `updatedAt`; aggregate time is the sum of every job's execution
duration and is useful for tracking duplicated work.

| Event | Run | Wall time | Jobs | Aggregate job time | Slowest job |
|---|---|---:|---:|---:|---:|
| Pull request | [30162092126](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30162092126) | 17m 12s | 24 | 2h 27m 49s | 16m 46s |
| Weekly publish | [30248081255](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30248081255) | 39m 15s | 55 | 6h 03m 07s | 18m 29s |
| Main publish | [29977649700](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/29977649700) | 48m 01s | 55 | 5h 55m 00s | 20m 24s |

The publish graph built all 20 native platform variants as `*-test`, then built
the same 20 variants again before publishing. The build-once graph removes that
second compile wave: a trusted platform image is staged by digest, verified
through that exact digest, assembled, and promoted without another Docker
build.

## First build-once PR measurement

The first complete build-once pull request exposed a different bottleneck:

| Event | Run | Wall time | Allocated jobs | Aggregate job time | Slowest platform |
|---|---|---:|---:|---:|---:|
| Pull request | [30501276174](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30501276174) | 22m 57s | 22 | 2h 52m 59s | self-hosted ROCm 7.2 AMD64, 22m 20s |

All 20 platform rows ran even though the pull request primarily changed
workflow orchestration. They spent 70m 18s aggregate in `sending cache export`
(about 41% of aggregate job time). The critical ROCm 7.2 row spent 1,016.8s in
cache export alone. Executed-job queueing was at most 41s, so runner capacity
was not the critical path.

The corrected PR contract selects changed image families plus one always-on
public CPU AMD64 contract row, reads trusted cache, and performs no PR cache
export. Exhaustive 20-platform construction and `mode=max` trusted-cache
population belong to main staging and the weekly promotion run.

## Build-once control before remote BuildKit

The last successful runs on commit `4e79e68`, after the build-once and PR
selection changes but before Depot remote BuildKit, are the comparison controls.
This prevents the Depot migration from taking credit for the earlier graph
reduction.

| Event | Run | Wall time | Executed jobs | Aggregate job time | Aggregate image-build steps |
|---|---|---:|---:|---:|---:|
| 20-platform PR | [30504335079](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30504335079) | 6m 22s | 22 | 1h 13m 07s | 1h 06m 19s |
| Main staging | [30522118156](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30522118156) | 42m 30s | 35 | 3h 14m 13s | 2h 58m 59s |

The main staging logs contain 20 `type=gha` cache exports totaling 1h 04m 44s.
That is 33.3% of all executed-job time and 36.2% of the image-build steps. The
critical public ROCm 7.2 row spent 8m 15s of its 18m 12s build step exporting
cache. Removing only that transfer, with no faster compute or cache reuse,
therefore has a conservative modeled benefit of 33.3% less aggregate job work;
it is a heuristic, not a post-Depot measurement.

## Depot remote BuildKit measurement

`depot/build-push-action` sends each platform build to the repository's Depot
project. BuildKit reuses that project's persistent SSD cache automatically, so
the workflow has no external `cache-from` or `cache-to` transfer. Trusted
staging and promotion still push each platform digest directly from the remote
builder to GHCR. Depot documents these behaviors in its
[container-build overview](https://depot.dev/docs/container-builds/overview),
[GitHub Actions integration](https://depot.dev/docs/container-builds/integrations/github-actions),
and [cache overview](https://depot.dev/docs/cache/overview).

Every matrix row uploads a machine-readable record containing the Depot project
and build IDs, result, platform, mode, and action duration. The build ID joins
that record to `depot list builds`, whose duration is the authoritative Depot
build duration. GitHub action duration remains orchestration-overhead evidence,
not a substitute for the Depot build record.

Depot Registry pull-through caching is deliberately evaluated after this
remote BuildKit cache. The Actions runner base is normally already present in
the persistent builder cache, so a mirror helps only on a real base-image cache
miss or builder replacement. Use the fresh-runner canary and the 20% plus
10-second median gate in `docs/OPERATIONS.md`; do not infer benefit from a warm
BuildKit run. Pull-through results say nothing about apt, Cargo, pnpm/npm,
CUDA/ROCm installation, native compilation, or layer export.

The first valid five-versus-five pull-through cohort was
[run 30776030734](https://github.com/Mesh-LLM/mesh-llm/actions/runs/30776030734)
on 2026-08-02. For Actions runner digest
`sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda`,
the upstream GHCR median was 12.055 seconds and the Depot median was 12.047
seconds: an 8 millisecond (0.1%) improvement. This fails both adoption
thresholds, so `DEPOT_REGISTRY_CACHE_ENABLED` remains `false`.

Populate this table only with successful runs from the migration commit and a
verified cache-state classification. Label a run cold only when the project was
new or empty immediately before it, or when independent Depot evidence proves
no relevant cache was available. Label a run warm only when Depot evidence or
BuildKit logs prove the relevant layers were reused. Sequence alone is not
cache-state evidence.

| Event | Run | Cache state | Wall time | Aggregate job time | Aggregate Depot build time | Net wall improvement | Net aggregate improvement |
|---|---|---|---:|---:|---:|---:|---:|
| 20-platform PR validation | [30702259904 attempt 1](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30702259904/attempts/1) | mixed: one-time cache-layout transition | 4m 10s | 56m 49s | 52m 30s | 34.6% | 22.3% |
| 20-platform PR validation | [30702259904 attempt 2](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30702259904/attempts/2) | verified warm: every row logged cached steps | 5m 21s | 9m 49s | 5m 13s | 16.0% | 86.6% |
| Main validation | Pending rollout | verify before labeling | — | — | — | — | — |
| Main validation | Pending rollout | verify before labeling | — | — | — | — | — |
| Main staging | [30703143674](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30703143674) | verified warm: expensive build layers reused across the matrix | 11m 03s | 2h 25m 34s | 1h 43m 26s | 74.0% | 25.0% |
| Main staging, remote verification | [30703744077](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30703744077) | verified warm: all 20 primary rows logged cached steps | 6m 55s | 1h 19m 28s | 1h 06m 49s | 83.7% | 59.1% |

The transition run's median and p95 Depot durations were 2m 34s and 3m 20s;
the verified-warm run reduced them to 6.5s and 44s. All 20 warm rows logged
BuildKit `CACHED` steps. GitHub-hosted runner queueing dominated its wall-time
tail: the slowest row waited 3m 58s for a runner and aggregate queue time was
29m 54s. Queue time is not included in aggregate job duration.

The first main staging run completed all 20 platform builds and all 35 executed
jobs successfully. Its median and p95 Depot durations were 5m 41s and 6m 25s,
with a 6m 26s slowest build. Direct GHCR pushes, SBOM, and provenance remained
enabled. Exact-digest verification still downloaded candidate layers to each
GitHub runner, accounting for much of the remaining orchestration overhead; a
follow-up routed that unchanged verification Dockerfile through Depot as well.
This run removed all external cache export but did not meet the 33.3%
aggregate-job target, so it is retained as an intermediate rollout result.

The remote-verification run again completed all 35 jobs and 20 platform builds.
Its primary-build median, p95, and slowest Depot durations were 4m 03s, 4m 49s,
and 4m 57s. Exact-digest verification fell from 28m 50s aggregate, 72s median,
and 2m 27s p95 to 2m 37s aggregate, 8s median, and 10s p95, a 90.9% aggregate
reduction. Compared with the pre-Depot main-staging control, primary build work
fell 62.7%, wall time fell 83.7%, and aggregate job time fell 59.1%. Direct GHCR
pushes, SBOM, provenance, immutable-digest verification, and every index
assembly remained enabled.

The migration pull request selected only the public CPU AMD64 contract row, so
it is not compared with the 20-platform PR control. It does provide a measured
cache-reuse benchmark for identical commit `3831dce` and matrix inputs:

| Cache state | Run attempt | Wall time | Aggregate job time | Depot build time | Wall reduction vs. cold | Aggregate reduction vs. cold |
|---|---|---:|---:|---:|---:|---:|
| Verified cold: empty project and 0 MB cache immediately beforehand | [30700898336 attempt 2](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30700898336/attempts/2) | 3m 02s | 2m 40s | 1m 59s | — | — |
| Verified warm: BuildKit logged 18 cached steps | [30700898336 attempt 3](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30700898336/attempts/3) | 57s | 35s | 1s | 68.7% | 78.1% |

The warm Depot build itself was 99.2% faster than the cold build. This isolates
the persistent-cache effect; it is not a before/after migration claim because
there is no pre-Depot control with this one-platform matrix.

Use GitHub API timestamps for workflow and aggregate job time. Do not use the
GitHub action step as Depot build time:

```bash
run_id=RUN_ID
run_attempt="${RUN_ATTEMPT:-$(gh run view "$run_id" --json attempt --jq .attempt)}"
repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
metrics_dir="$(mktemp -d)"
gh api "repos/$repository/actions/runs/$run_id/attempts/$run_attempt" \
  > "$metrics_dir/run.json"
gh api "repos/$repository/actions/runs/$run_id/attempts/$run_attempt/jobs" \
  --paginate > "$metrics_dir/jobs.json"
jq -s '
  .[0] as $run
  | [.[1].jobs[] | select(.conclusion != "skipped")] as $jobs
  | {
      wall_seconds:
        (($run.updated_at | fromdateiso8601)
          - ($run.run_started_at | fromdateiso8601)),
      executed_jobs: ($jobs | length),
      aggregate_job_seconds:
        ([$jobs[]
          | ((.completed_at | fromdateiso8601)
            - (.started_at | fromdateiso8601))]
          | add)
    }
' "$metrics_dir/run.json" "$metrics_dir/jobs.json"
```

Join the uploaded row records to Depot's machine-readable build list and emit
aggregate, median, p95, and slowest Depot duration:

```bash
run_id=RUN_ID
metrics_dir="$(mktemp -d)"
gh run download "$run_id" --pattern 'depot-build-*' --dir "$metrics_dir"
find "$metrics_dir" -type f -name '*.json' -print0 \
  | xargs -0 jq -s '.' > "$metrics_dir/rows.json"
depot list builds --project mzm95zcv7p --output json \
  > "$metrics_dir/depot-builds.json"
jq --slurpfile depot "$metrics_dir/depot-builds.json" '
  def median:
    sort as $values
    | ($values | length) as $count
    | if $count == 0 then null
      elif $count % 2 == 1 then $values[($count / 2 | floor)]
      else (($values[$count / 2 - 1] + $values[$count / 2]) / 2)
      end;
  def p95:
    sort as $values
    | ($values | length) as $count
    | if $count == 0 then null
      else $values[(($count * 0.95 | ceil) - 1)]
      end;
  ($depot[0] | INDEX(.id)) as $depot_by_id
  | map(. + {depot: $depot_by_id[.build_id]})
  | if any(.[]; .depot == null) then error("missing Depot build record") else . end
  | . as $builds
  | ($builds | map(.depot.duration)) as $durations
  | {
      schema: 1,
      github_run_id: $builds[0].github_run_id,
      project_id: $builds[0].project_id,
      build_count: ($builds | length),
      aggregate_depot_build_seconds: ($durations | add),
      median_depot_build_seconds: ($durations | median),
      p95_depot_build_seconds: ($durations | p95),
      slowest_depot_build_seconds: ($durations | max),
      builds: $builds
    }
' "$metrics_dir/rows.json"
```

Depot CLI 2.101.77 exposes container-build ID, status, start time, and duration.
It does not expose container-build retry count, cache-hit rate, CPU, or memory,
so those unsupported fields are deliberately absent from the machine-readable
report. Use the Depot dashboard or BuildKit logs only as separately recorded
cache-state or tuning evidence.

Calculate improvement as `(control - Depot) / control * 100`. Compare a Depot
pull request to run `30504335079` only when it also selects all 20 platforms;
otherwise establish a pre-Depot control with the same selected matrix. Compare
main staging to run `30522118156`. Report median and p95 platform-build time in
addition to totals so one fast family cannot hide a CUDA or ROCm regression.

## Depot Actions runner sizing comparison

Runner sizing is a separate change from remote BuildKit performance. For a
fair before-and-after comparison, dispatch one `validate` control with
`DEPOT_RUNNERS_ENABLED=false`, then the same `refs/heads/main` validation with
the setting restored to `true`. Keep `mesh_ref`, the complete platform matrix,
and `canary_id` identical. Record each workflow run's resolved `head_sha` and
compare only equal SHAs; `refs/heads/main` can move between dispatches. Classify
cache state independently for each run; cache sequence alone is not evidence of
a warm build.

For both runs, record wall time, aggregate job time, each native platform job's
duration, and run-start latency. Define run-start latency as
`job.started_at - run.created_at` from the Actions Jobs API. It includes
workflow scheduling and matrix setup, so it is not a direct runner-queue metric;
record a provider queue measurement separately if one is available. Capture the
job runner name and runner group through the Actions jobs API to prove the
selected path: the policy job stays GitHub-hosted; native AMD64 and Arm jobs use
`depot-ubuntu-24.04-16` and `depot-ubuntu-24.04-arm-16`; and prepare, index
assembly, staging, and promotion use `depot-ubuntu-24.04-4`. Do not compare a
validation run to a staging run, because staging adds digest verification and
index assembly work.

The first matched warm-cache comparison used the same `mesh_ref`, complete
matrix, and `canary_id` on 2026-08-02. Both runs resolved to
`36174f86f09a45d26c15b32986e007b81aa814de`. For cache evidence, all 20 native
platform rows in both logs reported the shared BuildKit steps `#12` through
`#22` as `CACHED`: 414 total cache lines (14--29 per row) for the control and
434 (16--29 per row) for the candidate. Record this per-platform coverage for
future comparisons; an aggregate cache-line count alone is insufficient.

| Path | Run / resolved SHA | Wall time | Aggregate job time | Native median / p95 / slowest | Depot build-record time |
|---|---|---:|---:|---:|---:|
| GitHub-hosted control | [30726381635](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30726381635) / `36174f86f09a45d26c15b32986e007b81aa814de` | 3m 07s | 14m 50s | 27s / 2m 17s / 2m 24s | 10m 50s (650s) |
| Depot runner candidate | [30726499385](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30726499385) / `36174f86f09a45d26c15b32986e007b81aa814de` | 4m 06s | 22m 51s | 44.5s / 2m 49s / 3m 18s | 11m 10s (670s) |

The raw native job accounting is below. `Build platform image once` is the
observed GitHub Actions step elapsed time, while build-record time is the
separately reported Depot build duration.

| Run | AMD64 native jobs: runner / action seconds | Arm native jobs: runner / action seconds | Prepare runner seconds | Native action total |
|---|---:|---:|---:|---:|
| GitHub-hosted control | 12: 710 / 591 | 8: 153 / 84 | 18 | 675 |
| Depot runner candidate | 12: 980 / 602 | 8: 349 / 86 | 33 | 688 |

The candidate used 12 `depot-ubuntu-24.04-16` jobs, eight
`depot-ubuntu-24.04-arm-16` jobs, one `depot-ubuntu-24.04-4` preparation job,
and a GitHub-hosted 9-second policy job. It validated the intended placement
but was 31.6% slower in wall time (`(246 - 187) / 187`) and 54.0% higher in
aggregate job time (`(1371 - 890) / 890`). Depot build-record time was 3.1%
higher (`(670 - 650) / 650`), while the observed build-action elapsed time was
1.9% higher (`(688 - 675) / 675`). This suggests runner overhead or scheduling,
rather than a meaningful change in remote BuildKit work. The follow-up pairs
below determine whether that first result holds.

The first-pair $0.7132 estimate is transparent arithmetic over observed runner seconds:
`980 / 60 * $0.032 + 349 / 60 * $0.032 + 33 / 60 * $0.008 = $0.5227 +
$0.1861 + $0.0044`. The two 16-vCPU labels use the listed `$0.032/min` rate;
the 4-vCPU preparation label uses `$0.008/min`. This is not a record of Depot
billed minutes or an invoice: obtain those from Depot before using the estimate
for budget reporting.

### Three-pair warm-cache result and scope decision

Two follow-up control/candidate pairs used the same `main` SHA, `mesh_ref`,
complete matrix, and respective `canary_id` values on 2026-08-02. All six
validations had cache evidence for every native row: 20 rows per run, with
control/candidate `CACHED` line totals of 414/434, 431/493, and 470/492. Each
row reported 14--32 cached layers, so this is a three-pair warm-cache result,
not a cold-cache or changed-source comparison.

`Active job time` below is the sum of the policy, preparation, and 20 native
platform jobs. The candidate-cost estimate uses observed native runner seconds
at the listed 16-vCPU rate plus preparation seconds at the 4-vCPU rate; it is
not Depot billed usage.

| Pair | Matched runs | Wall time: control → Depot | Active job time: control → Depot | Native runner time: control → Depot | Native build-action time: control → Depot | Candidate estimate |
|---|---|---:|---:|---:|---:|---:|
| 1 | [30726381635](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30726381635) → [30726499385](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30726499385) | 187s → 246s (+31.6%) | 890s → 1,371s (+54.0%) | 863s → 1,329s (+54.0%) | 675s → 688s (+1.9%) | $0.7132 |
| 2 | [30731681939](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30731681939) → [30731783911](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30731783911) | 125s → 141s (+12.8%) | 750s → 1,147s (+52.9%) | 724s → 1,101s (+52.1%) | 518s → 473s (-8.7%) | $0.5921 |
| 3 | [30731873054](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30731873054) → [30731966028](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30731966028) | 153s → 165s (+7.8%) | 562s → 1,298s (+131.0%) | 534s → 1,253s (+134.6%) | 358s → 579s (+61.7%) | $0.6731 |

The median pairwise effect is +16 seconds (+12.8%) wall time, +481 seconds
(+54.0%) active job time, and +466 seconds (+54.0%) native runner time. Native
build-action time has a +13-second (+1.9%) median but varies from -45 to +221
seconds, so it does not establish a remote BuildKit advantage. Depot was slower
in wall time and higher in runner time in every matched pair.

The rollout remains enabled for this repository's trusted builds at the current
16-vCPU native and 4-vCPU orchestration sizes, but no larger runner, consumer
workflow, or cross-repository expansion is justified by these measurements.
`Mesh-LLM/mesh-llm` is a downstream consumer of the published images, including
its CI, artifact, and release workflows, but it pins immutable image digests and
uses a separately scoped runner selector. This rollout does not trigger or
retime those jobs; a faster publication would only reduce availability lead
time before an explicit digest update. No such speedup was demonstrated here.

Retain the existing Depot build-duration report alongside runner measurements.
In the Depot dashboard, inspect CPU and memory utilization for the slowest
native jobs, cache-hit trends, and the monthly elapsed and billed minutes.
Depot flags CPU or memory peaks above 90% and OOM events; those are the
evidence needed to reconsider a larger runner. Any future size change needs a
new three-pair verified-warm comparison for that workload and utilization
evidence; a faster wall time alone is not sufficient. Depot bills the 16-vCPU
Linux runners at an 8x minute multiplier and the 4-vCPU runner at 2x. See
Depot's [runner type and billing table](https://depot.dev/docs/github-actions/runner-types)
and [container-build metrics guide](https://depot.dev/docs/container-builds/observability/container-build-metrics).

## Build-context measurement for future tuning

The reusable staging workflow now records each native row's Docker context
content-byte estimate and file count, together with runner OS/architecture,
Depot build/project IDs, and the shared cache boundary. The build action does
not expose context-upload duration or cache import/export duration separately,
so those fields remain explicitly unavailable rather than inferred from total
action time. These records provide the join keys for future per-architecture
and per-backend timing and cost comparisons.

For a pull_request run whose head repository differs from
Mesh-LLM/mesh-llm-runner-images, the record uses
cache.boundary=public-fork-isolated. Trusted same-repository pull requests
and main-branch, scheduled, or manually dispatched runs use
cache.boundary=repository-shared. The boundary is a measurement identity
for Depot cache access and keeps public-fork observations separate from the
repository's trusted cache population.

## Depot rollout and no-regression protocol

For the first gated pull request, trusted validation canary, and staged publish
after enabling Depot:

1. Record run wall time, aggregate job time, per-job run-start latency, and the
   slowest matrix row. Also record aggregate, median, and p95 Depot build
   duration from build records joined by build ID.
2. Dispatch `operation=validate` twice from `refs/heads/main` with the same
   lowercase `canary_id`. Classify either run as cold or warm only with the
   empty/new-project condition or independent cache-state evidence above.
3. Confirm the pull request selects only affected families plus the public CPU
   AMD64 contract row. For a public fork, confirm Depot marks builds isolated
   and gives them no project-cache read or write access.
4. Confirm the pull request uses GitHub-hosted x86 and Arm labels even while
   `DEPOT_RUNNERS_ENABLED=true`.
5. Confirm a trusted `refs/heads/main` validation or staging run uses the
   intended 16-vCPU x86 or
   Arm Depot label and 4-vCPU orchestration label.
6. Dispatch `operation=stage` on main and confirm it performs exactly 20
   platform builds, exact-digest verification, and all index assemblies while
   moving zero production aliases.
7. Confirm a feature-branch manual dispatch defaults to `validate` and rejects
   `stage` or `promote`.
8. Run `operation=promote` only after staging evidence is accepted. Confirm
   every versioned/content tag resolves to its descriptor digest, retain the
   previous/target latest-cohort manifest, and verify serialized reconciliation
   converges every `latest` tag.
9. Reject the rollout if any platform, label, attestation, candidate descriptor,
   family index, compatibility index, tag, or verification step differs from
   the control contract. Performance never overrides a functional regression.

The first targets are a verified-warm exhaustive validation under 6m 22s, main
staging under 42m 30s, at least 33.3% less aggregate main job time, and zero
external cache-export time. After three verified-warm runs, resize or autoscale
Depot builders only when independent Depot resource evidence identifies
saturation; otherwise preserve the current sizing and let cache reuse drive the
gain.

## Dependency cache-mount benchmark

On 2026-08-02, the public ARM64 CPU toolchain stage was rebuilt on `mesh1`
with BuildKit layer reuse disabled for `toolchain` and the result exported as
`cacheonly`. This forces every instruction to execute while preserving cache
mount contents, which isolates the invalidated-layer case these mounts target.
The input commit and manifest bundle were identical.

| Dockerfile | Cache state | Wall time |
|---|---|---:|
| `main` before cache mounts | No dependency cache mounts | 185s |
| Cache-mount branch | Partially warm after interrupted setup | 141s |
| Cache-mount branch | Verified warm | 150s |

The conservative verified-warm comparison is 18.9% faster than the control.
The dependency-warming instruction fell from 86.4 seconds to 65.3 seconds
(24.4%). Ordinary unchanged builds still use the faster Docker layer cache;
this result measures rebuilds where dependency inputs invalidate that layer.
