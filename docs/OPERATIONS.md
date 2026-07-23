# Rollout and verification

## Rollout order

1. Merge and run `Build and Push Runner Images` in `Mesh-LLM/mesh-llm-runner-images`.
2. Confirm CPU, Vulkan, and CUDA tags have AMD64 and ARM64 children and ROCm tags have an AMD64 child.
3. Merge the ARC/Flux changes in the `crusader-patio51` GitOps repository.
4. Reconcile `cluster-apps` and wait for the ARC controller and both scale-set Helm releases.
5. Copy the example workflows into `.github/workflows/` of a test branch and dispatch them.
6. After both ARC pools are green, remove the legacy static runner Deployments from the GitOps Kustomization in a separate change.

The initial GitOps change keeps the existing static runners online while ARC is introduced under new scale-set names. This makes rollback a workflow-label change rather than a cluster recovery operation.

## Acceptance matrix

| Path | Host | Execution image | Required proof |
| --- | --- | --- | --- |
| Public CPU/Vulkan | `ubuntu-24.04` | matching `public-<backend>@sha256:*` job container | image verifier and Cargo check pass |
| Public CUDA/ROCm | GitHub-hosted Linux | matching versioned public backend digest | compiler-only backend build passes |
| ARC AMD64/NVIDIA | Carrack K3s node | `self-hosted-cuda12@sha256:*` AMD64 | `x86_64`, `nvcc`, Cargo check, GPU device visible where requested |
| ARC ARM64 | CM4/CM5 K3s nodes | `self-hosted-cpu@sha256:*` or Vulkan/CUDA ARM64 child | `aarch64`, Cargo check, correct digest |
| Registry | GHCR | all variants | expected OCI architecture children are present |
| GitOps | Flux | ARC controller and scale sets | HelmReleases Ready and image policy current |

## Registry and local execution

```bash
cd /Users/ndizazzo/dev/mesh/mesh-llm-runner-images
./scripts/verify-end-to-end.sh
./scripts/verify-end-to-end.sh --all-backends
```

This inspects both OCI indexes and executes `verify-runner-image` under both platform emulations. If GHCR is private, authenticate first with `gh auth token | docker login ghcr.io -u YOUR_GITHUB_USER --password-stdin`.

## Flux and ARC

```bash
cd /Users/ndizazzo/dev/personal/stanton-patio51
kubectl kustomize deployments/ >/tmp/stanton-rendered.yaml
flux reconcile kustomization cluster-apps --with-source
flux get helmreleases --all-namespaces
kubectl get autoscalingrunnersets.actions.github.com -n arc-runners
kubectl get pods -n arc-runners -o wide
```

Or run the combined check. It uses the Flux CLI when available and falls back
to Flux reconciliation annotations through `kubectl`:

```bash
cd /Users/ndizazzo/dev/mesh/mesh-llm-runner-images
./scripts/verify-end-to-end.sh --cluster
```

Flux may use timestamp tags for discovery, but the applied HelmRelease must pin the resolved manifest digest. Backend-specific ARC pools must also carry matching hardware labels, node selectors, tolerations, and GPU resource requests. The `patio51-repo-auth` deploy key must have push permission for image automation; otherwise update the digest through a normal pull request.

## Scheduling proof

Dispatch `examples/workflows/k3s-self-hosted.yml` after copying it to an active workflow path. During execution:

```bash
kubectl get pods -n arc-runners -w
kubectl get pods -n arc-runners \
  -o custom-columns=NAME:.metadata.name,ARCH:.spec.nodeSelector.kubernetes\\.io/arch,IMAGE:.spec.containers[0].image,NODE:.spec.nodeName
kubectl describe pod -n arc-runners POD_NAME
```

The AMD64 pod must land on the `system=carrack` node and request `nvidia.com/gpu`. The ARM64 pod must show `kubernetes.io/arch=arm64`. An `exec format error` or `no match for platform in manifest` fails the architecture acceptance criterion.

## Rollback

Point the HelmRelease image fields at the previous immutable digest, reconcile Flux, and cancel queued jobs targeting the new scale sets. Existing ARC runner pods are ephemeral; no work directory or runner registration needs manual cleanup.
