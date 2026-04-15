# mesh-llm-runner-images

Build and publish sources for the Mesh-LLM self-hosted runner images.

## Published image

- `ghcr.io/mesh-llm/mesh-llm-cuda-runner:v3`

## Repository layout

- `Dockerfile` - CUDA-capable runner image based on `myoung34/github-runner`
- `scripts/install-cuda-toolchain.sh` - installs CUDA toolkit and build dependencies
- `.github/workflows/` - CI and publish workflows for this image repo

## Workflows

- `Build Test` - validates the image builds on pull requests and manual dispatch
- `Publish GHCR` - publishes `ghcr.io/mesh-llm/mesh-llm-cuda-runner`

## Manual workflow inputs

- `Publish GHCR`
  - `image_tag` (default `v3`)

The workflow path is now the supported way to build and publish the image.
