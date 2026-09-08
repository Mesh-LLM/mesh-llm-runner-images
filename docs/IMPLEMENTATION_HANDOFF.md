# Runner-image implementation handoff

Resumed at the user's request on 2026-09-07. The remaining objective is now an
active Codex goal. Continue to require each stage's validation before advancing.

## Remaining goal

Complete the remaining runner-image optimizations from the revised audit in
`/Users/ndizazzo/dev/mesh/worktrees/runner-image-improvements`, branch
`codex/runner-image-improvements`. Work in stages and require focused tests,
appropriate real image checks, and independent review before advancing.
Stages 1–6 are complete; continue with retained-cohort promotion and publication serialization. Coordinate tests and consumer integration
with task `01a07dce-676e-7640-9715-cf40b62790dc`, preserve its release changes and
frozen worktrees, and wait for any changes that invalidate a test's inputs.
Keep AMD64 CUDA compilation on the existing desk k3s ARC runner. Complete only
the supplemental work listed below; do not repeat the companion task's release,
packaging, registry-mirror, or shared history implementation.

## Completed stages

1. `5e4864b`: fixed rollback handling for previously absent aliases; added automatic
   test discovery and catalog-driven end-to-end verification, including web and
   expected SDK/Playwright arguments. Nine suites, ShellCheck, actionlint, and
   independent review passed.
2. `23e686d`: separated deterministic dependency payloads from provenance;
   included package-manager configuration; built dependency stores independently
   of SDKs; copied shared layers with explicit runner ownership; moved environment
   additions late; removed temporary node_modules trees; fixed collector failure
   propagation. Eleven suites, ShellCheck, actionlint, and independent review passed.

Stage 2 real local ARM64 validation passed:

- Public CPU and self-hosted CPU built-in image verifiers.
- npm and pnpm installs with networking disabled, no host cache mounts, and
  HOME=/github/home as both root and runner.
- Write checks for npm, pnpm, Cargo stores, and the Python venv.
- Vulkan shader compilation and image verification.
- Source-only changes reused warming and SDK installation; dependency changes
  reran warming while preserving SDK installation.
- Switching Vulkan to CPU reused warming and the same five dependency filesystem
  layer diffIDs. BuildKit reports linked merges as DONE in this case, so the test
  compares actual image identities rather than requiring a CACHED progress line.

Evidence remains under `/tmp/mesh-runner-stage2-cache-proof/layer-cache.vnLgc2`
and `/tmp/mesh-runner-stage2-*.log`. Recheck retained evidence without rebuilding:

```bash
PATH=/opt/homebrew/bin:$PATH bash tests/integration/layer-cache.sh \
  --evidence-only /tmp/mesh-runner-stage2-cache-proof/layer-cache.vnLgc2
```

These were development builds from the working tree after Stage 1, with its
revision supplied as the build argument. They are not published candidates.
No AMD64, CUDA, ROCm, web-browser, remote Actions, or production qualification is
claimed for the image restructuring. Filesystem diffIDs do not measure compressed
registry transfer savings. Temporary evidence and local image tags may expire.

## Stage 3 complete

The qualified changes:

- Add exact pnpm 10.34.5 and Rust 1.98.1 pins, validate requested versions, and
  propagate Rust bootstrap failures.
- Reuse the Actions runner already present in the pinned base instead of
  overlaying the same runner tarball in the self-hosted target.
- Install a 71-package Python runtime lock taken from the verified Stage 2
  environment, check its dependency closure, and require source requirements
  to be satisfied without a proposed installation.
- Move the verifier script late and wire the Python lock into Docker's context.

All 13 host suites, ShellCheck, actionlint, and diff checks passed after resume.
Real offline Python fixtures cover satisfied, missing, incompatible, direct-wheel,
and available-but-unlocked requirements without changing the installed environment.
The companion task independently reviewed Stage 3 and reran installer/Python tests
with no blockers. The additional Python lock integration helper also passed
independent review and static checks.

Stage 3 validation after resume:

- Docker context measurement now includes the Playwright pin and Python lock.
- ARM64 public/self-hosted image verifiers passed with pnpm 10.34.5 and Rust
  1.98.1. Both images passed offline npm/pnpm installs as root and runner,
  including store/venv write checks with HOME=/github/home.
- The self-hosted image passed its actual entrypoint version check for Actions
  runner 2.336.0, Node 20/24 paths, uid 1001, and exactly one runner distribution
  installation in image history.
- Native AMD64 public/self-hosted CPU builds passed on carrack. Both images
  passed offline npm/pnpm installs as root and runner. The inherited self-hosted
  runner entrypoint and Node checks passed. The actual installed set matches all
  71 source-lock packages on both architectures, and pip check passes offline.
- Local AMD64 emulation failed in the unchanged Ubuntu git-lfs package's
  postinst. Running that package directly in the pinned base reproduced a Go
  runtime SIGSEGV. The same package passes on native AMD64. No code workaround
  or weakened installation gate was added.
- These are development images built from the working tree after checkpoint
  f80dd2d, with that checkpoint's actual full SHA supplied. They are not
  published or claimed as immutable release candidates.

## Stage 4 complete

The working tree adds public AMD64 `ui` and `browser` families through
`Dockerfile.ui`, with catalog-validated workflow selection. The full `web`
image remains available. UI images have a separate, filtered package store,
stdlib Python, Node/pnpm/just, and the Actions convention paths. The browser
family adds the same pinned Playwright/Chromium installer as full web.

The lean store is built from scratch with `ONNXRUNTIME_NODE_INSTALL=skip`.
pnpm's lifecycle cache identity does not include that flag, so importing the
full image's store could restore CUDA/TensorRT side effects. Build logs confirm
the ONNX/protobufjs install hooks ran. Runtime tests explicitly enable hooks
and inspect both physical files and pnpm's hashed index mappings for GPU payloads.

Native AMD64 checks against immutable MeshLLM source
`cd602d6cba0f505fd9e1b4a6b5d1ca261a0032a0` have passed:

- UI: offline frozen install, lint, typecheck, 202 test files (1,660 passed,
  three skipped), production build, and GPU-payload checks. Total 108 seconds.
- Browser: the same UI checks, then 64 Playwright tests passed and two skipped.
  Browser E2E took 134 seconds. Networking was disabled and no host directories
  were mounted for either family; source arrived through `git archive` stdin.
- Full web: rebuilt with the extracted installers, passed the independent
  Playwright pin and full tool/AI verifier, then passed the offline verifier,
  root/runner npm and pnpm installs, and all 71 locked Python versions.
- Native ARM64 toolchain: rebuilt the extracted installers and passed offline
  exact pnpm/Rust/just/sccache/OpenAI checks with Node 24.

Verified runnable-image compressed layer descriptor totals (config, manifest,
index and attestation bytes excluded):

| Family | Compressed layer bytes | Reduction from full web |
| --- | ---: | ---: |
| Full web | 2,417,529,197 | — |
| UI | 849,113,102 | 64.9% |
| Browser | 1,263,899,888 | 47.7% |

These are image-size measurements, not observed pull-time savings. The helper
`scripts/measure-image-layers.py` verifies OCI metadata digests, sizes and
platform using small metadata reads; it does not use Docker's ambiguous `.Size`.
Local image indexes are UI `sha256:2a9f5971783276d100341ccade47b92fae2e489938475a625210549d71fd9a60`,
browser `sha256:aedbaff2b02f13ded390f74e28aa0c5766d32d4c123b8aa6f2025ad3752d16c1`,
and web `sha256:e6712b3efc869a9ea477429e6561a536ea885bba824cf9a5fe8d14c789785a06`.

Cache qualification passed in
`/tmp/mesh-runner-stage4-cache-proof/ui-layer-cache.gRXQzD`:

- Cargo/Python-only mutations reran cheap filtering, reused UI warming and
  browser installation, and preserved all three dependency layer diffIDs.
- A UI package-manager config mutation reran warming while retaining the
  cached browser installation.
- Switching that browser build to UI reused warming and all three physical
  dependency layers.

The first proof stopped because Docker 29's zero-byte WORKDIR history is
ambiguous. The corrected helper verifies exact OCI configuration bytes and
maps `history.empty_layer` to `rootfs.diff_ids`; the Stage 2 mapper's ambiguity
guard is unchanged. Another retained log exposed a frontend resolver reporting
DONE then CACHED. The parser now classifies only actual RUN/COPY/export steps
and still rejects conflicting evidence for those operations. Twelve focused
fixtures and independent review passed after that correction.

All 21 discovered host suites, ShellCheck, actionlint, and diff checks passed.
The final retained cache proof also passed an independent offline replay.
No remote Actions or production qualification is claimed for these new images.

Evidence is retained under `/tmp/mesh-runner-stage4-*`; UI/browser result files
are in `ui-proof/ui-image.IHIlPh` and `browser-proof/ui-image.RhbdP7` beneath
that prefix. Images were built from the Stage 4 working tree with checkpoint
`f7b89b16c9f39fcde411b32ddd169f091859dff7` supplied as runner revision. They
are development images, not published candidates. No consumer digest changed.

## Stage 5 identity foundation complete

Implemented independent tool/cache policy files, a runtime collector, strict
OCI receipt binding, staged receipt export, and an opt-in local offline proof.
The separate MeshLLM consumer worktree adds a checked image/epoch/seed/SDK
catalog without changing workflow, protected catalog, image pin, or cache-key
bytes. Existing Python test discovery checks its real workflow census and
planner output. Historical receipts, provenance and workload coverage stay null.
See `docs/RUNNER_IDENTITY.md` for the schema and trust limits.

Producer validation passed all 23 discovered suites, ShellCheck, actionlint and
diff checks. Subsequent targeted improvements passed 15 collector tests and 19
binder tests, including all 23 actual catalog platform rows. Independent review
caught and fixed omitted/unindexed dependency inputs, unsupported workflow
container syntax/extensions, changed observed tools with recomputed fingerprints,
and the real ROCm major/minor naming convention. Native checks did not rebuild
or change an image.

Final native AMD64 offline evidence, independently replayed against the exact
captured collector/pins/policy/Python lock:

- UI: `/tmp/mesh-runner-stage5-final-identities/runner-identity.aEzgtg`.
- Browser: `/tmp/mesh-runner-stage5-final-identities/runner-identity.ndG48f`.
- Full web: `/tmp/mesh-runner-stage5-final-identities/runner-identity.x357Vr`.
- Self-hosted CPU as its default runner user:
  `/tmp/mesh-runner-stage5-self-hosted-identity/runner-identity.IsxjjZ`.

These prove runtime collection, exact Python closure, complete dependency input
inventory and OCI binding. They do not qualify hosted Depot scratch export or
registry publication. The three Stage 4 images retain their original source
labels; the self-hosted image uses the frozen Stage 3 source
`a11e2ba4ca55b36361c19aa144f5f7bc45abd8a4` and runner checkpoint `f80dd2d`.
All local proof results explicitly preserve those qualification limits.

Consumer focused tests pass 35 cases. The first full gate ran 863 tests with
seven expected PowerShell skips and one unrelated host error: Python 3.13's
`Path.is_file()` raised on macOS `/usr/sbin/weakpass_edit` during the unchanged
Windows dependency test. The same seven focused tests pass under Python 3.14;
the complete gate passed with `uv run --python 3.14 --with PyYAML just
ci-validate`: 863 tests, 856 passes, seven expected skips, followed by all
CI/release/console/publish consistency checks. The unchanged Homebrew Rust/LLD
installation emitted deployment-target linker warnings while building xtask;
no Rust source was changed. Logs: `/tmp/mesh-runner-stage5-consumer-ci-validate.log`
and `/tmp/mesh-runner-stage5-consumer-ci-validate-python314.log`.

The CPU seed guard mismatch is documented but deliberately unchanged. Actual
trusted seed logs show Cargo-native C/C++ objects, but no llama.cpp runtime
build; the runtime made 319 C/C++ requests with zero cold hits. A spelling fix
alone could turn a harmless cold result into a failed warm-hit gate. Enable
only after a bounded real existing-seed runtime canary proves hits and total
restore/build benefit. Preserve the 1% runtime floor, 2 GiB cap, provider deny,
and image/epoch guards. Do not label the seed strictly Rust-only.

Next-stage read-only plan: use one test-only wrapper and independent expectations
in full public-test, self-hosted-test, lean public-test and Dockerfile.verify;
pass seven expectations and a separate verifier revision, run with networking
disabled, retain existing backend compilation and Chromium checks. Strengthen
end-to-end alias resolution to immutable digests separately. No next-stage
implementation can now begin.

## Stage 6 verification parity complete

All PR test targets and `Dockerfile.verify` now use one independent verification
wrapper, seven explicit expectations and a separate verifier-checkout SHA. The
wrapper executes the checkout's verifier/collector, validates Node 20/24 at both
canonical and Actions paths, and emits a report only on success. Verification
RUNs have networking disabled. Production Dockerfile instructions are unchanged.
The end-to-end deployment smoke resolves each alias once to an immutable digest,
keeps the mixed self-hosted child mapping, and accepts optional explicit source
expectations. It remains a smoke check, not receipt admission.

All 24 host suites, complete shell lint, actionlint and diff checks pass. The
wrapper suite has 15 cases, including execution of all catalog families through
the actual Dockerfile caller commands; the UI cache parser has 13 cases. Both
cache build helpers pass a separate verifier revision, and retained pre-wrapper
logs remain replayable with the same completion requirements.

Native AMD64 proofs under `/tmp/mesh-runner-stage6-complete-parity`:

- `verification-parity.Rnif8D`: browser on the Stage 4 image.
- `verification-parity.lhjOOU`: public CPU on the Stage 3 image.
- `verification-parity.ZgRkr4`: self-hosted CPU as runner on the Stage 3 image.

Each executes the real `Dockerfile.verify` scratch export against an exact local
name:tag@digest. It also executes the extracted, unchanged PR test COPY/RUN block
over the same production image. Both reports equal the independent offline
wrapper report and bind to the retained OCI metadata. Wrong source expectations
fail with no exported receipt. Input snapshots, raw logs, uncached RUN checks,
unchanged production image identities and current binder replay pass. These are
development proofs, not full production rebuilds or hosted/registry qualification.
The complete host log is `/tmp/mesh-runner-stage6-contracts-final.log`.

The companion task independently reviewed the Stage 6 Dockerfiles/workflow,
wrapper, native proof helper and end-to-end helper without findings, and reran
focused wrapper/end-to-end suites, actionlint and ShellCheck. Root reviewed the
delegated implementations and replayed all three native receipts. Review agents
subsequently exhausted account usage; do not assume they are still running.
Both Docker slots are free again; coordinate the next use.

## Remaining supplemental work

- Adopt qualified immutable UI/browser digests once available. Initial lean
  consumers are UI quality, UI E2E, and ordinary UI artifacts. Release UI still
  requires Cargo and Perl through `release-version.sh`; website builds call
  crate-docs; nightly stability needs the AI runtime. Keep those on full images.
- Complete rollout of the shared identity foundation; update ordinary CI and compiler-seed consumers together after image
  qualification. Preserve the companion task's release composer rows. The
  consumer inventory found a seed eligibility defect: the CPU runtime catalog
  emits `amd64`, but `ci-linux-runtime-slice.yml` requires `x86_64`. Qualify workload coverage before changing eligibility. Cover the
  real planner row behavior; CUDA/ROCm/Vulkan image/epoch mismatches must stay
  cold. Keep the protected `ci/slices.yml` and `ci/ownership.yml` bytes unchanged
  in the initial metadata landing. Historical image provenance remains unknown
  until verified; do not infer it from this runner repository's current HEAD.
- Qualify the final hosted build/staging path and representative remaining
  backend/architecture checks before production rollout. Stage 6 proves the
  shared local verification paths and Actions Node runtime paths; it does not
  substitute for a hosted canary or a native CUDA/ROCm build.
- Promote a retained, verified staged cohort without rebuilding. Bind admission
  to repository, trusted source workflow/ref/event, exact successful run attempt,
  artifact ID, complete descriptors, original source SHAs, and current catalog.
  Execute trusted checkout helpers; downloaded cohorts are data. Preserve original
  build attestations instead of attributing old builds to a new promotion checkout.
- Separate staging concurrency from one publication lock covering the complete
  versioned promotion, previous-alias snapshot, and latest reconciliation. Retain
  rollback evidence before changing latest aliases.
- Consolidate repeated family/index assembly behind the catalog and tested helpers,
  including explicit mixed-index source children and non-colliding descriptors.
- Extend the companion metrics framework with optional source-bound runner-image
  receipts for context, image layers, build/verification IDs and cache evidence.
  The companion task owns compact cuda12/rocm72/web classification, environment
  detection, and exact build/verification phase names; do not duplicate them.
  Preserve unknown values and distinguish GitHub wrapper time, Depot
  execution, filesystem identities, and compressed registry bytes.

The cohort/promotion and metrics designs were reviewed read-only by the existing
agents; those implementations have not started.

## Companion task and test coordination

Task: `codex://threads/01a07dce-676e-7640-9715-cf40b62790dc`, titled
"Analyze MeshLLM runner optimizations".

- MeshLLM: `/Users/ndizazzo/dev/mesh/worktrees/mesh-release-efficiency`.
  Checkpoint `cd602d6cba0f505fd9e1b4a6b5d1ca261a0032a0`; preserve this work.
- Packaging: `/Users/ndizazzo/dev/mesh/worktrees/packaging-runner-efficiency`.
  Checkpoint `253a33e`, including UI/browser metrics classification; draft PR #26
  passed hosted CI. This task independently reran the 25 shared metrics tests.
- The owner reported terminal MeshLLM ci-validate success: 828 tests, 821 passes,
  seven expected local PowerShell skips, plus required CI/release/publish checks.
  Packaging reported its full suite, five real Docker tests, and 23 metrics tests
  passing. Followup metrics tests reached 25, and packaging hosted CI passed
  at `0e894a7`. These are companion-reported results, not reruns by this task.
- Independently collected all 75 manifests/configuration files/target stubs from
  the frozen MeshLLM checkout. Its dependency payload is byte-identical to the
  one used for Stage 2 Docker tests. The companion release changes do not invalidate
  those dependency/cache results.
- The six release composers use existing CPU digest
  `sha256:8d93de6ba30173e825a16fdecf011f9c632edc6e1259df7289e491b0a05f829d`.
  AMD64 CUDA compilation remains on ARC. Preserve both decisions.
- Do not edit the frozen companion checkouts. Wait for a checkpoint or arrange
  separate dependent changes with their owner before consumer/metrics integration.
  The owner also passed an offline ARM64 v0.75.1 CUDA13 product composition
  through the pinned public CPU image, including runtime discovery and client
  readiness. This does not qualify the full release workflow or other platforms.

The companion reported all five PR #1684 lanes green at `cd602d6c`, then merged
updated main into its branch at `bea1dda6` and began revalidation. The immutable
source used by Stage 4 is unaffected. This task's separate consumer worktree is
`/Users/ndizazzo/dev/mesh/worktrees/mesh-runner-consumers`, branch
`codex/runner-consumer-images`, checkpoint `dbdedc4aeb0c1edbcd638f9bd9dd9feb1ff01a71`
based on `cd602d6c`, with the Stage 5 catalog, script/tests and documentation.
Existing workflows and protected catalogs
remain unchanged.

Stage 4 Docker work is complete; both Docker slots are free. Coordinate
the next use with the companion. Child agents are available again and have
independently reviewed Stage 4 image/installers, routing, verifiers, and evidence
helpers. The companion root provided the independent Stage 3 review. No branches were pushed, images published,
workflows dispatched, provider flags changed, or primary checkouts modified.

## Resume procedure

Read this handoff, inspect both committed and working-tree state, then refresh
the companion task's status. Use Homebrew Bash through PATH for local shell
tests. Before MeshLLM CI edits, read its complete manage-ci skill and required
inventory/topology documents. Validate each stage before starting the next one.
The user has explicitly resumed the goal. No recurring automation is configured.
