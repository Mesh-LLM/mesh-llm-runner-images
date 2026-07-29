# Publication and verification

## Publication order

1. Merge and run `Build and Push Runner Images` in `Mesh-LLM/mesh-llm-runner-images`.
2. Confirm the early workflow/candidate policy job succeeds.
3. Confirm every native platform candidate passes exact-digest verification and every family descriptor matches its registry index.
4. Confirm CPU, Vulkan, and CUDA indexes contain AMD64 and ARM64 children.
5. Confirm ROCm indexes contain the supported AMD64 child.
6. Confirm timestamp, MeshLLM compatibility, and immutable composite promotions and attestations succeed before any `latest` job starts.
7. Resolve the selected tag to its immutable OCI digest before updating a consumer.

Candidate tags are run-scoped reachability handles. Do not promote from a candidate tag or rebuild during publication; use the validated descriptor's exact digest. A failed candidate or versioned promotion leaves existing `latest` tags unchanged.

## Depot rollout gate

The policy job always runs on GitHub-hosted `ubuntu-24.04` and emits the tested downstream runner selection. Pull requests always use native GitHub-hosted `ubuntu-24.04` and `ubuntu-24.04-arm`. Trusted events use Depot only when both conditions hold:

- the Actions repository or organization variable `DEPOT_RUNNERS_ENABLED` is exactly `true`; and
- `github.ref` is exactly `refs/heads/main`.

When enabled, native builds use `depot-ubuntu-24.04-16` and `depot-ubuntu-24.04-arm-16`; orchestration and promotion use `depot-ubuntu-24.04-4`. An unset, false, or malformed variable falls back to GitHub-hosted runners. Pull requests, tags, and feature-branch workflow dispatches remain GitHub-hosted even if the variable is enabled.

The weekly default-branch publication is the deliberate scheduled exception: it is a trusted, high-value full rebuild and may use Depot when the same exact gate is enabled. A scheduled run on any other ref falls back to GitHub-hosted runners.

The organization runner-group restriction is the primary authorization boundary. The repository-local selector is defense in depth only because pull-request code can modify its own workflow and selector. Before enabling public-repository access or setting the variable:

1. configure the Depot runner group for selected repositories and include `Mesh-LLM/mesh-llm-runner-images`;
2. restrict workflow access and allowlist both `build-and-push.yml@refs/heads/main` and `stage-image-family.yml@refs/heads/main`; and
3. only after both restrictions are active, enable public access and set `DEPOT_RUNNERS_ENABLED=true`.

The reusable `stage-image-family.yml` workflow must remain on the allowlist because it directly owns Depot jobs. If jobs queue unexpectedly, unset the variable to roll back immediately; do not change workflow labels or loosen runner-group restrictions under incident pressure.

Depot Cache does not isolate entries by branch. The main-only provider gate therefore keeps pull-request code out of Depot runners and Depot Cache entirely. GitHub-hosted pull requests restore the standard GitHub Actions trusted/PR scopes and write only `pr-<number>`; trusted Depot publication reads and writes the Depot-backed trusted scope. Keep this provider and cache boundary when adding image families.

## Tag mutability

- Timestamp tags identify a publication run.
- `*-sha-<12-character MeshLLM revision>` remains a compatibility alias. A later runner-images revision for the same MeshLLM revision may intentionally move it.
- `*-mesh-<full MeshLLM revision>-runner-<full runner-images revision>` is the immutable source-identity tag. Promotion fails before changing any tags if that composite tag already points at another digest.
- `*-latest` moves only after the complete versioned cohort and its attestations succeed.

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
