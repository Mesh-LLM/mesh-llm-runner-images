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
| Exhaustive PR | [30504335079](https://github.com/Mesh-LLM/mesh-llm-runner-images/actions/runs/30504335079) | 6m 22s | 22 | 1h 13m 07s | 1h 06m 19s |
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

Every matrix row writes the Depot project ID, build ID, result, platform, mode,
and end-to-end action duration to the GitHub step summary. The build ID is the
join key for Depot's cache-hit and CPU, memory, and step-level metrics.

Populate this table only with successful runs from the migration commit. Use
the second identical validation as the warm-cache result; never compare a warm
Depot run only against a cold control.

| Event | Run | Cache state | Wall time | Aggregate job time | Aggregate Depot build time | Net wall improvement | Net aggregate improvement |
|---|---|---|---:|---:|---:|---:|---:|
| Main validation | Pending rollout | cold | — | — | — | — | — |
| Main validation | Pending rollout | warm | — | — | — | — | — |
| Main staging | Pending rollout | warm | — | — | — | — | — |

Use the GitHub API timestamps, not rounded UI labels. For a run ID:

```bash
run_id=RUN_ID
gh run view "$run_id" --json createdAt,updatedAt,jobs | jq '
  . as $run
  | [.jobs[] | select(.conclusion != "skipped")] as $jobs
  | {
      wall_seconds:
        (($run.updatedAt | fromdateiso8601) - ($run.createdAt | fromdateiso8601)),
      executed_jobs: ($jobs | length),
      aggregate_job_seconds:
        ([$jobs[]
          | ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))]
          | add),
      aggregate_build_seconds:
        ([$jobs[].steps[]
          | select(.name == "Build platform image once")
          | ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))]
          | add),
      slowest_build_seconds:
        ([$jobs[].steps[]
          | select(.name == "Build platform image once")
          | ((.completedAt | fromdateiso8601) - (.startedAt | fromdateiso8601))]
          | max)
    }
'
```

Calculate improvement as `(control - Depot) / control * 100`. Compare the
exhaustive PR to run `30504335079` and main staging to run `30522118156`.
Report median and p95 platform-build time in addition to totals so one fast
family cannot hide a CUDA or ROCm regression.

## Depot rollout and no-regression protocol

For the first gated pull request, trusted validation canary, and staged publish
after enabling Depot:

1. Record run wall time, aggregate job time, queue time, and the slowest matrix
   row. Also record aggregate, median, and p95 Depot build duration, cache-hit
   rate, and failed/retried build count.
2. Dispatch `operation=validate` twice from `refs/heads/main` with the same
   lowercase `canary_id`; use the first as cold-cache evidence and the second as
   warm-cache evidence from the same Depot project.
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

The first targets are a warm exhaustive validation under 6m 22s, main staging
under 42m 30s, at least 33.3% less aggregate main job time, and zero external
cache-export time. After three warm runs, resize or autoscale Depot builders
only when p95 CPU or memory saturation coincides with slow uncached steps;
otherwise preserve the current sizing and let cache reuse drive the gain.
