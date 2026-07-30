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

## Depot canary protocol

For the first gated pull request, trusted validation canary, and staged publish
after enabling Depot:

1. Record run wall time, aggregate job time, queue time, and the slowest matrix
   row.
2. Dispatch `operation=validate` twice from `refs/heads/main` with the same
   lowercase `canary_id`; confirm the second run restores the stable isolated
   `canary-<canary_id>` scope.
3. Confirm the pull request selects only affected families plus the public CPU
   AMD64 contract row, reads trusted cache, and exports no cache.
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

The first target is to beat the 17m 12s pull-request baseline and the 39m 15s
successful publish baseline while cutting trusted aggregate build work roughly
in half. Runner sizing should then be adjusted from Depot's CPU, memory, and
step-level utilization metrics rather than from wall time alone.
