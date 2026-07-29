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

## Depot canary protocol

For the first gated pull request and trusted publish after enabling Depot:

1. Record run wall time, aggregate job time, queue time, and the slowest matrix
   row.
2. Repeat an unchanged manual dry run to measure warm-cache behavior.
3. Confirm the pull request uses GitHub-hosted x86 and Arm labels even while
   `DEPOT_RUNNERS_ENABLED=true`.
4. Confirm a trusted `refs/heads/main` publish uses the intended 16-vCPU x86 or
   Arm Depot label and 4-vCPU orchestration label.
5. Confirm a feature-branch manual dispatch remains GitHub-hosted.
6. Confirm a pull request uses standard GitHub Actions cache and writes only
   its `pr-<number>` scope; confirm trusted Depot publication uses its separate
   trusted scope.
7. Confirm trusted publication performs exactly 20 platform builds, every
   versioned tag resolves to its candidate digest, and no `latest` tag moves
   before the complete versioned cohort succeeds.

The first target is to beat the 17m 12s pull-request baseline and the 39m 15s
successful publish baseline while cutting trusted aggregate build work roughly
in half. Runner sizing should then be adjusted from Depot's CPU, memory, and
step-level utilization metrics rather than from wall time alone.
