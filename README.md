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

## Local build

```bash
scripts/prepare-build-context.sh /Users/ndizazzo/dev/mesh/mesh-llm

docker buildx build \
  --platform linux/amd64 \
  --target public \
  --build-arg BACKEND=cpu \
  --build-arg RUNNER_ENVIRONMENT=public \
  --build-arg MESH_LLM_REVISION="$(git -C /Users/ndizazzo/dev/mesh/mesh-llm rev-parse HEAD)" \
  --load \
  -t mesh-llm-runner:public .

docker run --rm --entrypoint verify-runner-image mesh-llm-runner:public public cpu
```

Use target `self-hosted` and `RUNNER_ENVIRONMENT=self-hosted` for an image that includes the GitHub Actions runner. Select `BACKEND=cpu|vulkan|cuda|rocm`; CUDA additionally accepts `CUDA_SERIES`, while ROCm accepts `ROCM_VERSION` and currently requires AMD64.

## Maintenance pipeline

`.github/workflows/build-and-push.yml` runs on pull requests, pushes to `main`, a weekly schedule, and manual dispatch. It:

1. checks out the requested MeshLLM ref;
2. generates and uploads both manifest bundles;
3. builds and executes every supported environment, backend, and architecture combination;
4. publishes multi-platform tags, SBOMs, provenance, and GitHub attestations to GHCR.

Published tags are:

- `<environment>-<backend>-latest`
- `<environment>-<backend>-YYYYMMDDHHMMSS` for discovery and evaluation
- `<environment>-<backend>-sha-<MeshLLM revision>` for source traceability

Production consumers resolve one of these tags and pin its immutable manifest digest. Tags are not the production contract.

## Consumers

- `examples/workflows/public-github-hosted.yml` runs on `ubuntu-24.04` with the public image through job-level `container:`.
- `scripts/verify-end-to-end.sh` verifies the registry manifest lists and executes every supported architecture.

See `docs/AUDIT.md` for the source audit and `docs/OPERATIONS.md` for publication and registry-verification steps.
