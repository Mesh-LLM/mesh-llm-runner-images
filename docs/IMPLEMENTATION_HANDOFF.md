# Runner-image implementation handoff

Resumed at the user's request on 2026-09-07. The remaining objective is now an
active Codex goal. Continue to require each stage's validation before advancing.

## Remaining goal

Complete the remaining runner-image optimizations from the revised audit in
`/Users/ndizazzo/dev/mesh/worktrees/runner-image-improvements`, branch
`codex/runner-image-improvements`. Work in stages and require focused tests,
appropriate real image checks, and independent review before advancing.
Stage 3 is complete; continue with the lean UI/browser stage. Coordinate tests and consumer integration
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

## Remaining supplemental work

- Add public-only AMD64 UI and browser families through `Dockerfile.ui`, retaining
  the existing full web image and full-image layer boundaries. Preserve stdlib
  Python for the isolation audit before checkout. Initial lean consumers are UI
  quality, UI E2E, and ordinary UI artifacts. Release UI still requires Cargo
  and Perl through `release-version.sh`; website builds call crate-docs; nightly
  stability needs the AI runtime. Keep those consumers on full images.
  Route the closed Dockerfile choice through the family catalog and existing
  matrix generator. Keep the verifier's seven-argument interface, add explicit
  capabilities, and qualify native package lifecycle scripts and actual UI tests
  before adoption. Independent read-only design review is complete.
- Establish shared image metadata for digests, tool/dependency identity, and cache
  epochs; update ordinary CI and compiler-seed consumers together after image
  qualification. Preserve the companion task's release composer rows.
- Complete PR/staging verification parity, per-browser compatibility, backend
  coverage, and representative Actions runtime checks.
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
  Checkpoint `0e894a7`, including metrics followup; draft PR #26 passed hosted CI.
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

Stage 3 Docker work is complete. Coordinate the next use of local and native
carrack Docker with the companion before starting more builds. Native child agents hit an account
usage limit; the companion root provided the independent Stage 3 review. No branches were pushed, images published,
workflows dispatched, provider flags changed, or primary checkouts modified.

## Resume procedure

Read this handoff, inspect both committed and working-tree state, then refresh
the companion task's status. Use Homebrew Bash through PATH for local shell
tests. Before MeshLLM CI edits, read its complete manage-ci skill and required
inventory/topology documents. Validate each stage before starting the next one.
The user has explicitly resumed the goal. No recurring automation is configured.
