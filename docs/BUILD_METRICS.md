# Runner build measurements

The family workflow retains a separate receipt bundle for each production and
verification invocation. `runner-metrics-<environment>-<backend>-<platform>-<attempt>-<role>`
artifacts contain `receipt.json`, optionally the existing bound `identity.json`,
and optionally an invocation-scoped `cache.log`. Candidate and identity admission
artifacts retain their existing formats. Legacy `depot-build-*` records remain
available and share the same production timer snapshot as the new receipt.

Receipts use `type: mesh-llm-runner-build-metrics` and `schema: 1`:

```json
{
  "schema": 1,
  "type": "mesh-llm-runner-build-metrics",
  "identity": {
    "repository": "Mesh-LLM/mesh-llm-runner-images",
    "workflow_path": ".github/workflows/build-and-push.yml",
    "run_id": 123,
    "run_attempt": 1,
    "head_sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "runner_images_sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "mesh_llm_sha": "cccccccccccccccccccccccccccccccccccccccc",
    "environment": "public",
    "backend_id": "cpu",
    "platform": "linux/amd64"
  },
  "role": "production",
  "outcome": "success",
  "depot": {
    "build_id": "actual-build-id",
    "project_id": "mzm95zcv7p",
    "execution_seconds": null
  },
  "wrapper_elapsed_seconds": 42,
  "context": {"content_bytes": 1234, "file_count": 10, "transfer_seconds": null},
  "verification": null,
  "cache_evidence": null
}
```

Run ID and attempt are positive safe JSON integers. Revision strings are full
lowercase commit SHAs. `head_sha` records the PR head for pull requests, while
`runner_images_sha` identifies the source selected for the image and may be a
synthetic merge commit. Family and architecture must match the checked-in catalog.
Build and project IDs are nullable when unavailable after failure. Successful
invocations require both, and the project must match the workflow configuration.

`outcome` describes the build invocation and is one of `success`, `failure`,
`cancelled`, `skipped`, or `unknown`. A verification build can succeed while a
later identity-binding operation fails. That receipt has `outcome: success` and
`verification: null`. It does not assert successful runtime verification.
A failure before the verification command starts has an unknown invocation
outcome. Skipped invocations have null IDs, elapsed time, binding, and cache
evidence. Skipped verification also has null context; independently measured
production context may remain available. `always()` finalization preserves partial records when possible; runner
loss or failure before source selection can leave no receipt.

`wrapper_elapsed_seconds` measures the invocation wrapper, separately from Depot
execution. Production uses the Actions timer; verification uses a monotonic clock
around the CLI command and its streamed output. Depot metadata supplies IDs through
`depot.build.buildID` and `depot.build.projectID`; it supplies no execution duration.
`execution_seconds` and `transfer_seconds` therefore remain null. Context values
are the production repository's enumerated content estimate, excluding protocol
overhead. Verification context is unmeasured and remains null. Unknowns are never
converted to zero.

## Identity and layers

When binding completes, `verification` contains `verifier_sha`,
`identity_receipt_sha256`, `oci`, `layers`, and `totals`. The SHA-256 hashes the
exact retained identity bytes. `oci` has root, manifest, and config descriptors,
each with mediaType, digest, and size. `layers` preserves the bound identity's
ordered descriptors with their compression classification. No additional registry
request or image pull is needed.

`totals.layer_descriptor_bytes` sums every layer occurrence.
`totals.compressed_layer_descriptor_bytes` sums gzip and zstd layer occurrences.
`totals.distinct_layer_digests` is sorted and unique. Conflicting sizes or media
types for one digest fail validation. These values describe one runnable platform,
excluding attestations and other platforms. They are not filesystem sizes,
measured transfer bytes, or pull savings.

## Cache evidence

The deployed Depot CLI supports plain progress. Verification captures only that
invocation's combined output, preserving its exit status before any identity
binding. With actual Depot IDs available, `cache_evidence` contains:

```json
{
  "format": "buildkit-plain-v1",
  "sha256": "sha256:<64 lowercase hex>",
  "byte_count": 1234,
  "event_count": 20,
  "cached_operations": [4]
}
```

The sibling is `cache.log`. `event_count` counts nonblank log lines. The parser
counts only exact `#N CACHED` terminals following a `#N [stage ...] RUN`, `COPY`,
or `ADD` definition. Internal and resolver operations do not count. Executor
conflicts and duplicate terminals fail; repeated internal statuses are ignored.
Multiple build invocation markers fail. Other lines, including warnings and
command output, are uninterpreted. Operation numbers are local to this invocation.
They are not digests, layer counts, a cache hit rate, or evidence of saved time.

The file hash and receipt's role/build/project IDs retain the producer's assertion
that this output belongs to that invocation. They do not authenticate provenance.
Missing IDs leave cache evidence null. Production action logs are not reconstructed.

Explicit offline callers can also supply `--cache-format buildkit-rawjson-v1` with
`--cache-log FILE`. That format uses sibling `cache.jsonl` and reports
`cached_vertex_digests` instead of `cached_operations`. It accepts actual BuildKit
progress envelopes with vertexes/statuses/logs/warnings arrays and derives digests
from vertexes whose cached field is true. It rejects unsupported flat id/cached
objects. The current workflow does not enable rawjson on Depot.

Both formats are bounded to 8 MiB, 100000 lines, and 64 KiB per line. Capture drains
the command output while retaining at most 8 MiB plus one sentinel byte. Overflow
fails receipt validation; truncated output is never reported as complete evidence.
JSON receipts and identity input are bounded to 1 MiB; layer lists to 4096 entries.
All byte counts and totals must fit nonnegative safe JSON integers.

## Local use and shared history

`scripts/runner-build-metrics.py` writes a new immutable bundle. It reads
`METRICS_REPOSITORY`, `METRICS_WORKFLOW_PATH`, `METRICS_RUN_ID`,
`METRICS_RUN_ATTEMPT`, `METRICS_HEAD_SHA`, `METRICS_RUNNER_IMAGES_SHA`,
`METRICS_MESH_LLM_SHA`, `METRICS_ENVIRONMENT`, `METRICS_BACKEND_ID`, and
`METRICS_PLATFORM`. `DEPOT_PROJECT_ID` is the expected configured project.
Production additionally accepts `METRICS_OUTCOME`, `METRICS_BUILD_ID`,
`METRICS_PROJECT_ID`, `METRICS_ELAPSED_SECONDS`, `METRICS_CONTEXT_BYTES`, and
`METRICS_CONTEXT_FILES`. Empty optional measurements become null.

Verification accepts `--metadata`, `--state`, and `--identity`, with
`METRICS_VERIFIER_SHA` required when identity is present. State records the actual
invocation outcome and wrapper elapsed seconds, independent of later binding.
`--cache-log` is explicit and fails if absent or invalid. Missing optional metadata,
state, or identity paths are expected on partial attempts.

```sh
python3 scripts/runner-build-metrics.py --role production --output /tmp/production-bundle
python3 scripts/runner-build-metrics.py --role verification --output /tmp/verification-bundle \
  --metadata /tmp/verification-build.json --state /tmp/invocation-state.json \
  --identity /tmp/identity.json --cache-log /tmp/cache.log --cache-format buildkit-plain-v1
```

The companion shared-history change imports bundles explicitly and offline. The
automatic GitHub collector remains raw-only and downloads no receipt contents.
Imports must match exact repository, workflow, run, attempt, head, family, and
platform, then validate sidecar hashes and cross-role source consistency. Existing
schema-1 records remain readable, and validated enrichment survives raw refresh
without the original sidecars. Conflicting immutable imports fail. Local producer
receipts alone are not trusted workflow admission evidence.

Host tests use existing identity-binding fixtures and real BuildKit v0.32.2 cold,
warm rawjson, and warm plain output from a local scratch/COPY experiment. The
capture wrapper is tested with successful and failing commands, overflow, and
existing output refusal. These tests do not claim hosted workflow qualification.
