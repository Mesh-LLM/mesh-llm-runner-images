# PR 23 review follow-up

- [x] Address the four additional test-maintenance comments in the review body.
  QA: checksum fallback, installer extraction guard, policy-derived identity
  fixtures, and explicit metrics-fixture imports pass their focused host suites
  and shell checks; installer-boundary drift fails before sourcing any code.

- [x] Reject empty required promotion fields while preserving the optional
  trailing compatibility tag. QA: every required empty field fails before
  registry access; the existing empty compatibility-tag case still passes.
- [x] Diagnose unsupported pip before attempting report-based verification.
  QA: pip below 22.2 fails without invoking install; real supported pip retains
  the existing frozen-environment checks.
- [x] Restore the valid catalog before the generator-failure test.
  QA: the generator records that it ran, its nonzero exit rejects verification,
  and Docker remains unused.
- [x] Accept timed and untimed completed BuildKit exports.
  QA: layer comparison accepts both formats and still rejects missing exports
  and mismatching dependency layers.
- [x] Match the identity collector's lockfile grammar in the runtime proof.
  QA: comments and blank lines pass; malformed pins and duplicate normalized
  names fail; the complete host suite and shell checks pass.
