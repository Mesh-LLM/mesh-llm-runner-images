# Publication and verification

## Publication order

1. Merge and run `Build and Push Runner Images` on `refs/heads/main` in `stage` mode.
2. Confirm the early workflow/candidate policy job succeeds.
3. Confirm every native platform candidate passes exact-digest verification and every family descriptor matches its registry index.
4. Confirm CPU, Vulkan, and CUDA indexes contain AMD64 and ARM64 children.
5. Confirm ROCm indexes contain the supported AMD64 child.
6. Confirm `stage` moved no timestamp, source-compatibility, content, or `latest` tag.
7. Run `promote` explicitly, or allow the trusted weekly schedule to do so.
8. Confirm versioned/content promotions and attestations succeed, then retain the generated latest-cohort manifest before reconciliation starts.
9. Resolve the selected tag to its immutable OCI digest before updating a consumer.

Candidate tags are run-scoped reachability handles. Do not promote from a candidate tag or rebuild during publication; use the validated descriptor's exact digest. A failed candidate or versioned promotion leaves existing `latest` tags unchanged.

The three execution modes are separate contracts:

- `validate` performs no registry login or package write and is the manual default;
- `stage` is main-only and pushes run-scoped candidates, exact-digest verification, and complete family indexes without moving production aliases; and
- `promote` is main-only and consumes the same-run verified descriptors before moving versioned aliases and reconciling `latest`.

Main pushes use `stage`; the weekly default-branch schedule uses `promote`. A feature-branch dispatch cannot stage or promote, and a pull request cannot select a mutation mode.

## Depot remote builder

All platform image builds use Depot remote BuildKit, regardless of which
GitHub Actions runner hosts the orchestration step. Before merging the
migration:

1. create one Depot container-build project dedicated to this repository;
2. set the Actions repository or organization variable `DEPOT_PROJECT_ID` to
   that project ID; and
3. add OIDC trust relationships for this repository's
   `build-and-push.yml` and `stage-image-family.yml` workflows.

The called workflow requires a non-empty project ID, and both reusable-workflow
call sites grant only `contents: read` plus `id-token: write`; staging also has
the existing `packages: write`. Depot's project cache is automatic, persistent,
and shared by builds authorized for that project. Public fork pull requests are
isolated by Depot and receive no project-cache read or write access. Trusted
staging and promotion authenticate to GHCR locally, then the remote builder
pushes each immutable platform candidate directly to GHCR. There is no
`type=gha` cache import or export.

`DEPOT_PROJECT_ID` is configuration, not a credential. OIDC is the
authorization boundary; do not add a long-lived `DEPOT_TOKEN` unless OIDC is
unavailable and a separate security review approves the exception.

## Depot runner rollout gate

The policy job always runs on GitHub-hosted `ubuntu-24.04` and emits the tested downstream runner selection. Pull requests always use native GitHub-hosted `ubuntu-24.04` and `ubuntu-24.04-arm`. Trusted calls use Depot only when every condition holds:

- the Actions repository or organization variable `DEPOT_RUNNERS_ENABLED` is exactly `true`;
- `github.repository` is exactly `Mesh-LLM/mesh-llm-runner-images`;
- `github.ref` is exactly `refs/heads/main`;
- `github.workflow_ref` is exactly `Mesh-LLM/mesh-llm-runner-images/.github/workflows/build-and-push.yml@refs/heads/main`; and
- the event is a trusted push, schedule, or manual dispatch.

When enabled, native builds use `depot-ubuntu-24.04-16` and `depot-ubuntu-24.04-arm-16`; orchestration and promotion use `depot-ubuntu-24.04-4`. An unset, false, or malformed variable falls back to GitHub-hosted runners. Pull requests, tags, and feature-branch workflow dispatches remain GitHub-hosted even if the variable is enabled.

The weekly default-branch publication is the deliberate scheduled exception: it is a trusted, high-value full rebuild and may use Depot when the same exact gate is enabled. A scheduled run on any other ref falls back to GitHub-hosted runners.

The organization runner-group restriction is the primary authorization boundary. The repository-local selectors and the called workflow's independent literal-label mapping are defense in depth because pull-request code can modify its own local workflow. Before enabling public-repository access or setting the variable:

1. configure the Depot runner group for selected repositories and include `Mesh-LLM/mesh-llm-runner-images`;
2. restrict workflow access and allowlist both `build-and-push.yml@refs/heads/main` and `stage-image-family.yml@refs/heads/main`; and
3. only after both restrictions are active, enable public access and set `DEPOT_RUNNERS_ENABLED=true`.

The reusable `stage-image-family.yml` workflow must remain on the allowlist because it directly owns Depot jobs. If jobs queue unexpectedly, unset the variable to roll back immediately; do not change workflow labels or loosen runner-group restrictions under incident pressure.

As of 2026-07-29, the live repository has no main-branch ruleset or branch protection. Enabling public Depot access remains blocked until main protection, required review for workflow changes, and the selected-workflow runner-group restriction are verified. This document records the blocker; it does not authorize changing repository settings.

The runner gate is independent of the remote builder: pull requests remain on
GitHub-hosted runners, but their Docker builds still execute remotely in Depot.
Public fork builds use Depot's automatic isolated-build behavior. Authorized
same-repository builds share the project's persistent BuildKit cache; cache
reuse is content-addressed and no branch-specific `type=gha` scopes remain.
The validated `canary_id` is retained as a correlation label in run summaries,
and two identical main validations provide the cold/warm cache comparison.

## Tag mutability

- Timestamp tags identify a publication run.
- `*-sha-<12-character MeshLLM revision>` remains a compatibility alias. A later runner-images revision for the same MeshLLM revision may intentionally move it.
- `*-digest-sha256-<64-hex manifest digest>` is the immutable content tag. Source revisions remain full OCI labels and descriptor fields; they are not collision-proof content identity when provenance or resolved packages vary.
- `*-latest` is an eventual multi-tag view. Before changing it, CI uploads a 14-day cohort manifest containing every target and previous digest. `scripts/reconcile-image-cohort.sh MANIFEST target` converges an interrupted promotion; `previous` restores recorded prior digests where a prior tag existed.

Latest reconciliation is deliberately serialized after the complete versioned cohort and attestations succeed. The registry cannot atomically move all family tags, so consumers that need an atomic release must use the immutable digests recorded in the cohort manifest rather than observing `latest` during reconciliation.

## Candidate retention

Candidate tags are named with the run ID and attempt; the target retention window is 14 days. GHCR package-version deletion can remove every tag sharing a digest, including promoted content, so no automated cleanup may delete a candidate version merely by age. Cleanup must first prove either that the candidate was never promoted or that deleting its package version cannot remove a non-candidate/content reference. Until a tag-only or separately isolated candidate-repository cleanup is proven, candidate cleanup is an external rollout blocker and operators must not use package-version deletion as a substitute.

Use [CI_BENCHMARKS.md](CI_BENCHMARKS.md) for the pre-Depot baseline and the first-canary measurement protocol.

## Registry and local verification

From the repository root:

```bash
./scripts/verify-end-to-end.sh
./scripts/verify-end-to-end.sh --all-backends
```

This inspects the OCI indexes and executes `verify-runner-image` for every
supported platform. If GHCR is private, authenticate before running it.

## Consumer rollback

Restore the previous immutable digest in the owning consumer repository. Do not
retag an existing image or use a mutable tag as a rollback mechanism.
