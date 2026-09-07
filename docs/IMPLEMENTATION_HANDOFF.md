# Runner-image implementation handoff

Paused at the user's request on 2026-09-07. Do not resume implementation or tests
until the user explicitly resumes this work. The objective below is a draft;
no active Codex goal or automation was created.

## Remaining goal

Complete the remaining runner-image optimizations from the revised audit in
`/Users/ndizazzo/dev/mesh/worktrees/runner-image-improvements`, branch
`codex/runner-image-improvements`. Work in stages and require focused tests,
appropriate real image checks, and independent review before advancing. Resume
with the unfinished Stage 3 checkpoint. Coordinate tests and consumer integration
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

## Stage 3 checkpoint, not yet qualified

The unfinished changes:

- Add exact pnpm 10.34.5 and Rust 1.98.1 pins, validate requested versions, and
  propagate Rust bootstrap failures.
- Reuse the Actions runner already present in the pinned base instead of
  overlaying the same runner tarball in the self-hosted target.
- Install a 71-package Python runtime lock taken from the verified Stage 2
  environment, check its dependency closure, and require source requirements
  to be satisfied without a proposed installation.
- Move the verifier script late and wire the Python lock into Docker's context.

Installer fixtures and static checks passed in the implementing agent. Python
lock contents match the observed freeze, excluding pip; syntax and ShellCheck
passed. The complete Stage 3 suite and Docker builds have NOT run.

Next actions after explicit resume:

1. Review the checkpoint diff against `23e686d` and finish Python behavioral
   fixtures for satisfied, missing, incompatible, and available-but-unlocked
   requirements. The Python agent was stopped before those tests were written.
2. Update Docker context measurement and fixtures to include both the existing
   Playwright pin and new Python lock. The current estimator omits config files.
3. Validate the inherited Actions runner's startup/version, user, entrypoint,
   Node paths, and absence of a second runner installation layer. The pinned
   base's existing listener was verified as version 2.336.0.
4. Run the whole contract suite and lints, then real CPU checks and Python lock
   qualification on ARM64 and AMD64. Recheck offline stores and cache boundaries
   where the final change affects them. Obtain independent review before advancing.

## Remaining supplemental work

- Scope smaller ordinary CI/UI/browser images by actual consumer needs while
  preserving required tools, archives, caches, and backend capabilities.
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
- Extend the companion metrics framework with compact cuda12/rocm72/web job
  classification, exact build/verification phase names, and optional source-bound
  runner-image receipts for context, image layers, build/verification IDs and cache
  evidence. Preserve unknown values and distinguish GitHub wrapper time, Depot
  execution, filesystem identities, and compressed registry bytes.

The cohort/promotion and metrics designs were reviewed read-only by the existing
agents; those implementations have not started.

## Companion task and test coordination

Task: `codex://threads/01a07dce-676e-7640-9715-cf40b62790dc`, titled
"Analyze MeshLLM runner optimizations".

- MeshLLM: `/Users/ndizazzo/dev/mesh/worktrees/mesh-release-efficiency`.
  Base `03267ccf0af51f7f452b57462e196cde1abe97f4`; changes remain uncommitted and frozen.
- Packaging: `/Users/ndizazzo/dev/mesh/worktrees/packaging-runner-efficiency`.
  Base `1b47fef79558babf6d41d24a21d2fcba3e1066d3`; changes remain uncommitted and frozen.
- The owner reported terminal MeshLLM ci-validate success: 828 tests, 821 passes,
  seven expected local PowerShell skips, plus required CI/release/publish checks.
  Packaging reported its full suite, five real Docker tests, and 23 metrics tests
  passing. These are companion-reported results, not reruns by this task.
- Independently collected all 75 manifests/configuration files/target stubs from
  the frozen MeshLLM checkout. Its dependency payload is byte-identical to the
  one used for Stage 2 Docker tests. The companion release changes do not invalidate
  those dependency/cache results.
- The six release composers use existing CPU digest
  `sha256:8d93de6ba30173e825a16fdecf011f9c632edc6e1259df7289e491b0a05f829d`.
  AMD64 CUDA compilation remains on ARC. Preserve both decisions.
- Do not edit the frozen companion checkouts. Wait for a checkpoint or arrange
  separate dependent changes with their owner before consumer/metrics integration.
  A real release canary remains pending in that task.

All local builds/tests and child agents were stopped or completed at pause.
The shared Docker slot is free. No branches were pushed, images published,
workflows dispatched, provider flags changed, or primary checkouts modified.

## Resume procedure

Read this handoff, inspect both committed and working-tree state, then refresh
the companion task's status. Use Homebrew Bash through PATH for local shell
tests. Before MeshLLM CI edits, read its complete manage-ci skill and required
inventory/topology documents. Validate each stage before starting the next one.
Do not schedule or start this remaining goal until explicitly resumed.
