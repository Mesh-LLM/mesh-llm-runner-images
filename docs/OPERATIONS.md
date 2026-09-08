# Publication and verification

## Publication order

1. Merge and run `Build and Push Runner Images` on `refs/heads/main` in `stage` mode.
2. Confirm the early workflow/candidate policy job succeeds.
3. Confirm every native platform candidate passes exact-digest verification and every family descriptor matches its registry index.
4. Confirm CPU, Vulkan, and CUDA indexes contain AMD64 and ARM64 children.
5. Confirm ROCm indexes contain the supported AMD64 child.
6. Confirm `stage` moved no timestamp, source-compatibility, content, or `latest` tag.
7. Dispatch `promote` with the successful stage run's `staged_run_id` and exact `staged_run_attempt`, or let the weekly schedule stage and promote a new cohort.
8. Confirm staging attestations and versioned/content promotions succeed, then retain the generated latest-cohort manifest before reconciliation starts.
9. Resolve the selected tag to its immutable OCI digest before updating a consumer.

Candidate tags are run-scoped reachability handles. Do not promote from a candidate tag or rebuild during publication; use the validated descriptor's exact digest. A failed candidate or versioned promotion leaves existing `latest` tags unchanged.

The three execution modes are separate contracts:

- `validate` performs no registry login or package write and is the manual default;
- `stage` is main-only and pushes run-scoped candidates, exact-digest verification, and complete family indexes without moving production aliases; and
- manual `promote` is main-only and admits an exact successful retained run attempt, without resolving `mesh_ref` or rebuilding; the weekly schedule stages and seals its own verified cohort before publication.

Main pushes use `stage`; the weekly default-branch schedule uses `promote`. A feature-branch dispatch cannot stage or promote, and a pull request cannot select a mutation mode.

## Depot remote builder

All platform image builds use Depot remote BuildKit, regardless of which
GitHub Actions runner hosts the orchestration step. Before merging the
migration:

1. use the dedicated Depot project `mzm95zcv7p` configured in the checked-in
   workflows; and
2. add OIDC trust relationships for this repository's
   `build-and-push.yml` and `stage-image-family.yml` workflows.

The called workflow requires that exact checked-in project ID, and both reusable-workflow
call sites grant only `contents: read` plus `id-token: write`; staging also has
`packages: write` and `attestations: write` for provenance produced during staging. Depot's project cache is automatic, persistent,
and shared by builds authorized for that project. Public fork pull requests are
isolated by Depot and receive no project-cache read or write access. Trusted
staging authenticates to GHCR locally, then the remote builder
pushes each immutable platform candidate directly to GHCR. There is no
`type=gha` cache import or export.

The checked-in project ID is configuration, not a credential. OIDC is the
authorization boundary; do not add a long-lived `DEPOT_TOKEN` unless OIDC is
unavailable and a separate security review approves the exception.

## Depot Registry pull-through base

The Dockerfile's canonical default remains the digest-pinned
`ghcr.io/actions/actions-runner` image. Trusted `stage` and `promote` builds can
opt into a Depot pull-through repository for that one upstream repository.
Validation mode, pull requests, feature refs, tags, and untrusted callers always
use the upstream reference.

Depot pull-through repositories are one-to-one with upstream repositories. In
the Depot dashboard, configure `https://ghcr.io` as an upstream registry, then
create a pull-through repository whose upstream path is
`actions/actions-runner`. Record only its relative Depot repository name.
Before enablement, use MeshLLM's `depot-registry-canary.yml` from `main` to
compare this exact digest over five fresh runners per source. Enable it only if
the retained result proves identical digests plus at least 20% and 10 seconds
of median pull improvement.

Required repository variables:

- `DEPOT_REGISTRY_CACHE_ENABLED`: exact `true` enables the mirror for trusted
  staging/promotion; any other value selects GHCR.
- `DEPOT_REGISTRY_HOST`: the organization host in the form
  `<org-id>.registry.depot.dev`.
- `DEPOT_ACTIONS_RUNNER_REPOSITORY`: the relative pull-through repository name.

No registry secret is stored. Depot pre-authenticates each trusted Actions job
to pull the organization's Registry images with a short-lived runner
credential. Cache selection therefore also requires
`DEPOT_RUNNERS_ENABLED=true`; the workflow rejects a cached reference on a
GitHub-hosted runner. The Dockerfile keeps the exact upstream manifest digest
in either reference.

To roll back immediately, set `DEPOT_REGISTRY_CACHE_ENABLED=false` or remove
the variable. This optimization affects only base-image transfer on a cache
miss. It does not accelerate apt repositories, manifest warming, Cargo,
pnpm/npm, CUDA/ROCm installer downloads, native compilation, or layer export.

## Depot runner rollout gate

The policy job always runs on GitHub-hosted `ubuntu-24.04` and emits the tested downstream runner selection. Pull requests always use native GitHub-hosted `ubuntu-24.04` and `ubuntu-24.04-arm`. Trusted calls use Depot only when every condition holds:

- the Actions repository or organization variable `DEPOT_RUNNERS_ENABLED` is exactly `true`;
- `github.repository` is exactly `Mesh-LLM/mesh-llm-runner-images`;
- `github.ref` is exactly `refs/heads/main`;
- `github.workflow_ref` is exactly `Mesh-LLM/mesh-llm-runner-images/.github/workflows/build-and-push.yml@refs/heads/main`; and
- the event is a trusted push, schedule, or manual dispatch.

When enabled, native builds use `depot-ubuntu-24.04-16` and `depot-ubuntu-24.04-arm-16`; orchestration and promotion use `depot-ubuntu-24.04-4`. An unset, false, or malformed variable falls back to GitHub-hosted runners. Pull requests, tags, and feature-branch workflow dispatches remain GitHub-hosted even if the variable is enabled.

The weekly default-branch publication is the deliberate scheduled exception: it is a trusted, high-value full rebuild and may use Depot when the same exact gate is enabled. A scheduled run on any other ref falls back to GitHub-hosted runners.

Depot runners are an existing organization-wide runner path shared by this repository and other organization repositories. Enabling this repository's gate does not change the shared runner group's membership or workflow access. The repository-local selector and the called workflow's independent literal-label mapping request the Depot labels only for the trusted conditions above.

The reusable `stage-image-family.yml` workflow owns the Depot jobs and must retain its independent mapping for the exact `build-and-push.yml@refs/heads/main` caller. If jobs queue unexpectedly, unset the variable to roll back immediately; do not change runner labels under incident pressure.

### Live enablement and audit

The live setting is deliberately managed in GitHub Actions rather than checked into source.
It is currently `DEPOT_RUNNERS_ENABLED=true`, which enables this repository's existing
organization-wide Depot runner path. The `Default` Depot runner group is shared by multiple
organization repositories; shared runner availability is separate from this workflow's
per-run selection gate.

`main` is protected with a pull request requirement, one fresh approval after the most recent push,
resolved conversations, linear history, no force pushes or deletions, and administrator enforcement. Those branch protections keep an
unreviewed push from replacing the protected release workflow gate.

Every job that can select Depot checks the exact repository, `refs/heads/main`,
`build-and-push.yml@refs/heads/main` workflow reference, a trusted event, and
the literal enabled value. The reusable workflow independently repeats that
mapping. Pull requests, tags, and feature-branch workflow dispatches therefore
use GitHub-hosted runners; the matrix test asserts both the trusted Depot labels
and the GitHub-hosted fallback labels. To roll back immediately, set
`DEPOT_RUNNERS_ENABLED=false` or remove the variable.

The runner gate is independent of the remote builder: pull requests remain on
GitHub-hosted runners, but their Docker builds still execute remotely in Depot.
Public fork builds use Depot's automatic isolated-build behavior. Authorized
same-repository builds share the project's persistent BuildKit cache; cache
reuse is content-addressed and no branch-specific `type=gha` scopes remain.
The first migration measurements did not establish a cost-versus-latency case
for a larger native runner, a new bake group, a matrix concurrency cap, or a
public/self-hosted/backend project split. Keep the checked-in 16-vCPU native
labels and existing job allocation until a matched warm comparison includes
Depot billed minutes and independent CPU/memory evidence; do not tune by wall
time alone.
The validated `canary_id` is retained as a correlation label in run summaries,
but sequence does not establish cache state. A validation may be labeled cold
only when the Depot project is new or empty immediately beforehand, or when
independent Depot evidence confirms that relevant cache is unavailable. A run
may be labeled warm only when the Depot dashboard or BuildKit logs prove reuse
of the relevant layers.

## Tag mutability

- Timestamp tags retain the original staging timestamp, including on later promotion or retry.
- `*-sha-<12-character MeshLLM revision>` remains a compatibility alias. A later runner-images revision for the same MeshLLM revision may intentionally move it.
- `*-digest-sha256-<64-hex manifest digest>` is the immutable content tag. Source revisions remain full OCI labels and descriptor fields; they are not collision-proof content identity when provenance or resolved packages vary.
- `*-latest` is an eventual multi-tag view. Before changing it, CI uploads a 14-day cohort manifest containing every target and previous digest. `scripts/reconcile-image-cohort.sh MANIFEST target` converges an interrupted promotion; `previous` restores recorded prior digests where a prior tag existed.

One `runner-image-publication` concurrency group covers versioned promotion, the previous-latest snapshot, and reconciliation. Staging does not take this lock. `queue: max` and `cancel-in-progress: false` allow up to 100 pending publications without replacement; GitHub cancels additional arrivals. Latest reconciliation starts only after the complete versioned cohort succeeds, with build attestations already created by the original stage attempt. The registry cannot atomically move all family tags, so consumers that need an atomic release must use the immutable digests recorded in the cohort manifest rather than observing `latest` during reconciliation.

## Retained-cohort admission

Every staging attempt retains `staged-cohort-RUN_ID-ATTEMPT` for 14 days. It
contains the original source revisions, catalog identity, all 16 index
candidates, and all 23 platform receipts with their exact OCI metadata bytes.
Platform, identity, and index artifacts include the attempt in their names.
A partial retry cannot silently reuse another attempt's evidence; rerun all
staging jobs to create a complete new attempt.

Manual promotion checks the GitHub API for the exact attempt's successful
conclusion, repository and head repository, main branch, workflow path and ID,
and source SHA. It downloads one unexpired immutable artifact ID, validates
its archive digest and size, then parses only `staged-cohort.json`. The current
checkout supplies all executable helpers. Admission requires the current
catalog and tool/cache policy and independently re-binds each receipt to its
retained registry bytes. Missing, extra, mixed-source, expired, or incompatible
cohorts fail before registry writes. Use a fresh stage when policy has changed.

The same-running-attempt exception is available only to the seal job after
all staging dependencies succeed. External manual admission always requires
a completed successful attempt. Build attestations belong to the original
stage; promotion does not assert that its current checkout built old images.

Local tests cover admission failures, immutable digest reuse, publication retry,
and failure before latest writes. Hosted artifact admission, provenance, and
concurrent queue behavior still require a trusted canary before rollout.
GitHub documents [the concurrency queue](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
Pinned actionlint 1.7.12 lacks that key, so `.github/actionlint.yaml` suppresses
only its exact unknown-queue diagnostic in the caller workflow. The cohort
test enforces the complete fixed lock mapping. Remove this exception when the
pinned linter supports it.

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

## Bumping the baked Playwright/Chromium version

The `web` and `browser` backends bake a specific Chromium build, declared once in
`config/playwright-pin.txt` (currently the `playwright` package version, which
mesh-llm's pinned `@playwright/test` version always matches exactly — Playwright
ships those two packages in lockstep). This image is the stable side of that
pairing: it does not read mesh-llm's lockfile at build time, and mesh-llm does
not re-derive its pin from this image. Each side asserts the other's value
independently — `verify-runner-image` checks the baked version against an
optional expected argument; mesh-llm's `ui_e2e` job checks its own
`@playwright/test` resolution against `/etc/mesh-runner-playwright-version`
inside the container before running `pnpm run test:e2e` (see
`ci-web-slice.yml`).

**Bump order is mandatory and one-directional: this repo first, mesh-llm
second.**

1. Bump `config/playwright-pin.txt` here, land it, and run this repo's
   publication order above through `promote` so new `public-web` and
   `public-browser` digests exist in the registry.
2. Only then bump `@playwright/test` in `crates/mesh-llm-ui/pnpm-lock.yaml`
   and each consumed browser-capable image digest in mesh-llm, in the same PR.

Doing it in the other order — bumping mesh-llm's lockfile first — leaves
`ui_e2e`'s preflight version check failing on `main` with no image to point at
yet; that check is deliberately strict (mode C in the runner-images design:
it fails loudly on a mismatch rather than letting Playwright silently
re-download a browser to match its own lockfile, which is exactly the apt
call this backend exists to remove). If it blocks a bump, the fix is always
promoting the corresponding browser-capable image with the new pin.
