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

## Depot rollout and no-regression protocol

For the first gated pull request, trusted validation canary, and staged publish
after enabling Depot:

1. Record run wall time, aggregate job time, queue time, and the slowest matrix
   row. Also record aggregate, median, and p95 Depot build duration from build
   records joined by build ID.
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
