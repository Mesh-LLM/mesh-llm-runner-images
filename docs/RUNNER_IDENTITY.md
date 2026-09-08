# Runner image identity

Staged verification emits a separate `runner-identity-ENV-BACKEND-ARCH` artifact.
It binds observed runtime inputs to the exact OCI index, platform manifest and
configuration descriptors tested by `Dockerfile.verify`. Candidate descriptors
retain their existing schema. The receipt is retained for 14 days.

The trusted verification checkout supplies `config/tool-pins.json`,
`config/cache-policy.json`, the Python lock and the collector. These files are
copied into a separate directory so they cannot overwrite the candidate's
stamps or lock before comparison. The receipt records the verification revision
separately from the source revisions stamped into the candidate.

Full public/self-hosted test targets, lean public test targets and staged
verification all call `verify-runner-candidate.sh`. It invokes the verifier and
collector from that independent directory, executes both canonical and Actions
Node 20/24 paths, and emits the runtime report only after success. All four
Dockerfile callers use `RUN --network=none`; production image instructions are
unchanged. Test targets require an explicit `VERIFIER_REVISION` build argument.

`collect-runner-identity.py` observes Node version/ABI, pnpm version/store format,
just, Rust commit/host/LLVM, Cargo, sccache, OpenAI npm, Playwright/Chromium, and
Python version/ABI/package inventory where applicable. Full images must match
the frozen Python runtime inventory, excluding pip from lock equality; its
version remains part of the observed inventory hash. Lean images report absent
compiler and AI tools as `null`.
Verification requires the independent pins to match actual observations.

The dependency identity hashes the canonical path-sorted manifest/config/stub
index after checking every file's bytes and rejecting unindexed payload files.
Source audit files remain separate. This is an identity for dependency inputs,
not a digest of the downloaded Cargo or pnpm store. UI and full dependency
profiles also record their different ONNX lifecycle policy.

Cache fingerprints describe partial runtime inputs and explicit per-store
epochs. A provenance-only source change does not invalidate them. Consumers
must still include the relevant lockfiles and recipe inputs. Native compiler
reuse additionally requires compatible image/toolchain epochs, target, features,
SDK/system libraries and compiler/linker flags. Matching Rust and sccache
versions alone never authorizes compiler-object reuse between images.

`bind-runner-identity.py` checks the collector's observations against the trusted
pins and policy, then verifies raw OCI index and child-manifest hashes and sizes.
The workflow redirects `docker buildx imagetools inspect --raw` directly to files
to preserve those bytes. Layer descriptor sizes and compression types are
included; they are neither filesystem sizes nor measured pull savings. The
configuration descriptor is bound through the child manifest; this step does
not claim to download or inspect the configuration blob.

A receipt is evidence from its producing workflow, not a signature or permission
to promote. Admission must verify the producing repository, workflow, source
revision, successful run attempt and artifact identity. The initial consumer
catalog in MeshLLM records historical image references and native/cache epochs
while leaving unavailable receipts, provenance and workload coverage `null`.
Its drift check compares actual workflow bindings and planner output. It does
not change current consumer images, cache keys, or restore eligibility.

For a retained image on an explicitly configured native SSH Docker host, run:

```bash
bash tests/integration/runner-identity.sh \
  LOCAL_IMAGE SSH_HOST public browser MESH_SHA none none RUNNER_SHA LOG_DIRECTORY
```

This opt-in test streams the trusted collector and expectations into a fresh
container, disables networking, runs the image verifier, and binds the result
to metadata read through the host's containerd socket. The evidence includes
copies of the exact collector and expected files used. The result explicitly
states that hosted workflow execution and registry publication were not
qualified. It does not rebuild or publish an image.

`tests/integration/verification-parity.sh` takes the same arguments and also
executes `Dockerfile.verify` against the retained `name:tag@digest` using the
native Docker driver. It extracts the exact PR test block and runs its unchanged
COPY/RUN instructions atop that same production image, exports both runtime
reports, and compares them with the offline baseline. It verifies an uncached
RUN, rejection of a wrong source SHA without an exported receipt, immutable
production image identity and captured input hashes. This tests the verification
paths without rebuilding the production image. It does not qualify hosted Depot
execution, registry publication, or another architecture/backend.

The deployment smoke helper, `scripts/verify-end-to-end.sh`, resolves each alias
once and runs all its architectures on that immutable digest with networking
disabled. Optional `--mesh-revision SHA` and `--runner-images-revision SHA` add
independent source expectations. It retains the embedded image verifier and
does not emit a qualified identity receipt.
