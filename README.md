# MeshLLM runner images

This repository builds a backend-specialized MeshLLM CI image family from one shared core toolchain. Every backend is available as a GitHub-hosted job container (`public`) and an image containing the GitHub Actions runner (`self-hosted`):

- `public-cpu-*` / `self-hosted-cpu-*`
- `public-vulkan-*` / `self-hosted-vulkan-*`
- `public-cuda12-*` / `self-hosted-cuda12-*`
- `public-cuda13-*` / `self-hosted-cuda13-*`
- `public-rocm70-*` / `self-hosted-rocm70-*`
- `public-rocm72-*` / `self-hosted-rocm72-*`

CPU, Vulkan, and CUDA tags support `linux/amd64` and `linux/arm64`. ROCm tags are intentionally `linux/amd64` only because that is the currently supported MeshLLM ROCm CI target. The compatibility aliases preserve the existing image contract: `public-*` is CPU on both architectures, while `self-hosted-*` combines CUDA 12 on AMD64 with CPU on ARM64. The existing GHCR package name is retained to avoid a registry and credential migration.

## Design

The image has four layers of configuration:

1. `profiles/common.yml` is the shared operating-system toolchain found in MeshLLM CI and build scripts.
2. `profiles/backends/*.yml` contains CPU, Vulkan, CUDA, or ROCm SDK packages; the owning installer handles vendor repositories and compilers.
3. `profiles/public.yml` and `profiles/self-hosted.yml` contain environment-only additions.
4. `scripts/prepare-build-context.sh` checks out the requested MeshLLM revision, discovers its Rust, Node, Python, and Go manifests, and creates one bundle per runner environment. The Docker build injects the matching bundle and warms Cargo, pnpm, npm, and Python dependencies.

The YAML profiles use a deliberately small schema (`schema`, `profile`, and `apt.packages`) that is parsed by portable Bash without Python or Ruby. The manifest bundle is content-addressed in `manifest-index.json`. Cargo target stubs retain the complete workspace graph without copying or publishing MeshLLM source code in the runner image.

### Base image

The toolchain stage builds from `ACTIONS_RUNNER_BASE_IMAGE`, whose default is
`ghcr.io/actions/actions-runner:latest` pinned by digest in the Dockerfile. It
provides the GitHub Actions runner agent, the `runner` user (uid 1001), the
`docker` group (gid 123), `/usr/bin/docker` (Docker CLI, no daemon), and Node 20
and 24 runtimes under `/home/runner/externals/node{20,24}/bin`.
`scripts/install-core-tools.sh` wires Node from these externals into
`/usr/local/bin` instead of installing Node from an apt repository;
`docker-ce-cli` is no longer apt-installed because the base already ships a
compatible Docker client.

Trusted staging/promotion may replace only the registry/repository portion with
a Depot Registry pull-through mirror while retaining the exact upstream digest.
The opt-in gate, repository mapping, short-lived pull-token authentication, and
rollback procedure are documented in `docs/OPERATIONS.md`. Validation and pull
request builds always use the canonical upstream reference.

Both final stages provision the GitHub Actions root-system conventions required when the image is used as a job `container:` (DinD sidecar, rootless Podman, or any setup where the runner cannot rely on kubelet bind mounts):

- `/__e/node24` → symlinked to `/home/runner/externals/node24`
- `/__e/node20` → symlinked to `/home/runner/externals/node20`
- `/__w`, `/github/home`, `/github/workflow` → directories with mode 0777

The `public` stage bakes these as `USER root` (matching the public-container root convention); the `self-hosted` stage bakes them before restoring `USER runner` so the runner agent's `run.sh` entrypoint still executes with uid 1001. `scripts/verify-runner-image.sh` asserts both the `/__e/node24/bin/node` symlink and its canonical source under `/home/runner/externals/`, plus `docker --version`, so regressions of the `/__e/node24/bin/node: no such file or directory` failure mode are caught at build time.

## Local build

```bash
scripts/prepare-build-context.sh /Users/ndizazzo/dev/mesh/mesh-llm

docker buildx build \
  --platform linux/amd64 \
  --target public \
  --build-arg ACTIONS_RUNNER_BASE_IMAGE=ghcr.io/actions/actions-runner:latest@sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda \
  --build-arg BACKEND=cpu \
  --build-arg RUNNER_ENVIRONMENT=public \
  --build-arg MESH_LLM_REVISION="$(git -C /Users/ndizazzo/dev/mesh/mesh-llm rev-parse HEAD)" \
  --build-arg RUNNER_IMAGES_REVISION="$(git rev-parse HEAD)" \
  --load \
  -t mesh-llm-runner:public .

docker run --rm --entrypoint verify-runner-image mesh-llm-runner:public public cpu
```

Use target `self-hosted` and `RUNNER_ENVIRONMENT=self-hosted` for an image that includes the GitHub Actions runner. Select `BACKEND=cpu|vulkan|cuda|rocm`; CUDA additionally accepts `CUDA_SERIES`, while ROCm accepts `ROCM_VERSION` and currently requires AMD64.

## Maintenance pipeline

`.github/workflows/build-and-push.yml` runs on pull requests, pushes to `main`, a weekly schedule, and manual dispatch. It:

1. validates the workflow and immutable-candidate contract before expensive work;
2. checks out the requested MeshLLM ref and generates both manifest bundles;
3. builds affected pull-request families plus one always-on public CPU AMD64 contract row, while trusted main and scheduled runs remain exhaustive;
4. verifies each trusted staged image through its exact registry digest, then assembles and validates one immutable index descriptor per family;
5. promotes timestamp, MeshLLM compatibility, and digest-derived immutable tags from those descriptors without rebuilding;
6. records the complete previous/target `latest` map, then reconciles the eventual `latest` cohort from that retained manifest.

Execution is explicit: `validate` builds test targets without registry writes, `stage` pushes and verifies run-scoped candidates without moving production aliases, and `promote` performs the same staging before versioned and eventual-`latest` reconciliation. Manual dispatch defaults to `validate`; any staging or promotion requires the exact repository, `refs/heads/main`, and the default-branch caller workflow. Main pushes stage candidates, while the weekly schedule performs the deliberate production promotion.

Pull requests receive no package-write permission and run only affected
families plus the public CPU AMD64 contract row. Every platform build uses
Depot remote BuildKit and its persistent project-scoped cache; no job imports
or exports `type=gha` cache archives. Public fork builds are isolated from the
project cache by Depot. Trusted staging and promotion push immutable platform
digests directly from the remote builder to GHCR, while GHCR remains the
canonical registry. The checked-in Depot project configuration and required
OIDC trust setup are documented in `docs/OPERATIONS.md`.

Supported environments, backends, architectures, compatibility aliases, and extra indexes are declared in `config/runner-image-families.json`; `scripts/generate-workflow-matrices.sh` validates that descriptor and generates both build and promotion matrices.

Pull requests always use native GitHub-hosted `ubuntu-24.04` and `ubuntu-24.04-arm` runners. The policy job is also fixed to GitHub-hosted Ubuntu and selects the downstream provider. The called family workflow independently derives literal runner labels and permits Depot only for the exact repository, default-branch caller workflow, `refs/heads/main`, a trusted event, and `DEPOT_RUNNERS_ENABLED=true`. It accepts no caller-provided runner JSON. All mismatches fall back to GitHub-hosted labels or fail before checkout.

The weekly default-branch publication is intentionally Depot-eligible when that gate is enabled: it is a trusted, high-value full image rebuild. Scheduled runs on any other ref remain GitHub-hosted.

The runner gate is independent of container builds: GitHub-hosted pull-request
runners still dispatch Docker builds to Depot. Depot isolates public fork
builds from the project cache, while authorized same-repository builds share
the persistent content-addressed cache.

Published tags are:

- `<environment>-<backend>-latest`
- `<environment>-<backend>-YYYYMMDDHHMMSS` for discovery and evaluation
- `<environment>-<backend>-sha-<12-character MeshLLM revision>` is a mutable compatibility alias and may move when runner-image inputs change
- `<environment>-<backend>-digest-sha256-<64-hex manifest digest>` is the collision-proof immutable content identity and refuses conflicting overwrite

MeshLLM and runner-images source revisions remain full OCI labels and candidate-descriptor fields. They are not used as immutable tag identity because provenance timestamps and resolved package inputs can legitimately change content for the same source pair. Production consumers resolve a selected tag and pin its immutable manifest digest; tags are not the production contract.

## Consumers

- `examples/workflows/public-github-hosted.yml` runs on `ubuntu-24.04` with the public image through job-level `container:`.
- `scripts/verify-end-to-end.sh` verifies the registry manifest lists and executes every supported architecture.

See `docs/AUDIT.md` for the source audit and `docs/OPERATIONS.md` for publication and registry-verification steps.
