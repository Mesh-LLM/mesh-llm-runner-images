# Publication and verification

## Publication order

1. Merge and run `Build and Push Runner Images` in `Mesh-LLM/mesh-llm-runner-images`.
2. Confirm every build-test matrix row succeeds before publication begins.
3. Confirm CPU, Vulkan, and CUDA indexes contain AMD64 and ARM64 children.
4. Confirm ROCm indexes contain the supported AMD64 child.
5. Resolve the selected tag to its immutable OCI digest before updating a consumer.

## Registry and local verification

```bash
cd /Users/ndizazzo/dev/mesh/mesh-llm-runner-images
./scripts/verify-end-to-end.sh
./scripts/verify-end-to-end.sh --all-backends
```

This inspects the OCI indexes and executes `verify-runner-image` for every
supported platform. If GHCR is private, authenticate before running it.

## Consumer rollback

Restore the previous immutable digest in the owning consumer repository. Do not
retag an existing image or use a mutable tag as a rollback mechanism.
