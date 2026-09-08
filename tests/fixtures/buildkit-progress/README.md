# BuildKit progress fixtures

These exact streams came from a local Docker Buildx experiment on 2026-09-07 with
BuildKit v0.32.2 and the Docker driver. The Dockerfile used scratch and one COPY of
a local payload, requiring no external image pull. `cold.jsonl` has no cached
vertices; `warm.jsonl` has one cached COPY vertex; `warm.log` has the corresponding
plain `#4 CACHED` operation. Capture modes were rawjson and plain respectively.
No Depot build was run to produce these fixtures. Depot's deployed CLI uses plain
progress, so only the plain evidence variant is enabled in the family workflow.
