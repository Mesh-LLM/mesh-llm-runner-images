#!/usr/bin/env python3
"""Retain bounded, source-bound measurements for one Depot invocation."""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sys
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("oci", Path(__file__).with_name("measure-image-layers.py"))
oci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oci)
require = oci.require
MAX_JSON = 1024 * 1024
MAX_CACHE = 8 * 1024 * 1024
MAX_SAFE = 2 ** 53 - 1
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=no_duplicates,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(f"invalid JSON number: {value}")))


def read_bytes(path, limit=MAX_JSON):
    path = Path(path)
    require(not path.is_symlink() and path.is_file(), f"expected regular file: {path}")
    require(path.stat().st_size <= limit, f"input exceeds {limit} bytes")
    with path.open("rb") as source:
        raw = source.read(limit + 1)
    require(len(raw) <= limit, f"input exceeds {limit} bytes")
    return raw


def sha256(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def text(value):
    require(isinstance(value, str) and 0 < len(value) <= 256 and not any(ord(char) < 32 or ord(char) == 127 for char in value), "invalid bounded string")
    return value


def number(value, integer=True):
    require(type(value) in ((int,) if integer else (int, float)) and 0 <= value <= MAX_SAFE
            and math.isfinite(value), "invalid nonnegative safe number")
    return value


def optional_number(value):
    if value in (None, ""):
        return None
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+", value), "invalid integer measurement")
    return number(int(value))


def identity_from_env(env):
    result = {key: env.get("METRICS_" + key.upper(), "") for key in (
        "repository", "workflow_path", "head_sha", "runner_images_sha", "mesh_llm_sha",
        "environment", "backend_id", "platform")}
    for value in result.values():
        text(value)
    for key in ("head_sha", "runner_images_sha", "mesh_llm_sha"):
        require(SHA.fullmatch(result[key]), f"invalid {key}")
    require(result["repository"] == "Mesh-LLM/mesh-llm-runner-images", "unexpected repository")
    require(result["workflow_path"] == ".github/workflows/build-and-push.yml", "unexpected workflow")
    for key in ("run_id", "run_attempt"):
        result[key] = optional_number(env.get("METRICS_" + key.upper()))
        require(result[key] is not None and result[key] > 0, f"invalid {key}")
    catalog = decode(read_bytes(Path(__file__).resolve().parents[1] / "config/runner-image-families.json"))
    backend = next((item for item in catalog["backends"] if item["id"] == result["backend_id"]), None)
    require(backend is not None, "unknown backend")
    require(result["environment"] in backend.get("environments", catalog["environments"]), "unknown environment")
    require(result["platform"] in ["linux/" + arch for arch in backend["architectures"]], "unsupported platform")
    return result


def cache_proof(raw, format_name="buildkit-rawjson-v1"):
    require(len(raw) <= MAX_CACHE, "cache evidence exceeds 8 MiB")
    lines = raw.splitlines()
    require(len(lines) <= 100000, "too many cache evidence lines")
    if format_name == "buildkit-plain-v1":
        return plain_cache_proof(raw, lines)
    require(format_name == "buildkit-rawjson-v1", "unsupported cache evidence format")
    cached = set()
    count = vertices = 0
    for line in lines:
        require(len(line) <= 65536, "cache evidence line exceeds 64 KiB")
        if not line.strip():
            continue
        event = decode(line)
        require(isinstance(event, dict), "cache event must be an object")
        keys = {"vertexes", "statuses", "logs", "warnings"} & set(event)
        require(keys, "unsupported progress envelope")
        count += 1
        for key in keys:
            require(isinstance(event[key], list) and all(isinstance(item, dict) for item in event[key]), "invalid progress envelope")
        for vertex in event.get("vertexes", []):
            vertices += 1
            require(isinstance(vertex.get("digest"), str) and DIGEST.fullmatch(vertex["digest"]), "vertex requires digest")
            if "cached" in vertex:
                require(type(vertex["cached"]) is bool, "cached must be boolean")
            if vertex.get("cached") is True:
                cached.add(vertex["digest"])
    require(vertices > 0, "cache evidence has no vertices")
    return {"format": format_name, "sha256": sha256(raw), "byte_count": len(raw),
            "event_count": count, "cached_vertex_digests": sorted(cached)}


def plain_cache_proof(raw, lines):
    definitions, terminals, cached, earlier_terminals = {}, {}, set(), set()
    count = markers = 0
    for raw_line in lines:
        require(len(raw_line) <= 65536, "cache evidence line exceeds 64 KiB")
        line = raw_line.decode("utf-8")
        if not line.strip():
            continue
        count += 1
        if re.match(r"^#0 building\b", line):
            markers += 1
            require(markers <= 1, "multiple build invocations in cache evidence")
        header = re.fullmatch(r"#([1-9][0-9]*) (\[[^\]\r\n]+\] (?:RUN|COPY|ADD) .+)", line)
        if header:
            operation = number(int(header[1]))
            require(operation not in definitions or definitions[operation] == header[2], "conflicting operation definition")
            require(operation not in earlier_terminals or operation in definitions, "operation definition after terminal")
            definitions[operation] = header[2]
        terminal = re.fullmatch(r"#([1-9][0-9]*) (CACHED|DONE(?: [0-9]+(?:\.[0-9]+)?s)?|ERROR: .+)", line)
        if terminal:
            operation = number(int(terminal[1]))
            earlier_terminals.add(operation)
            if operation in definitions:
                require(operation not in terminals, "duplicate or conflicting operation terminal")
                terminals[operation] = terminal[2]
                if terminal[2] == "CACHED":
                    cached.add(operation)
    require(count > 0, "empty cache evidence")
    return {"format": "buildkit-plain-v1", "sha256": sha256(raw), "byte_count": len(raw),
            "event_count": count, "cached_operations": sorted(cached)}


def verification_metrics(raw, identity):
    receipt = decode(raw)
    require(type(receipt.get("schema")) is int and receipt["schema"] == 1 and receipt.get("type") == "mesh-llm-runner-image-identity", "unsupported identity receipt")
    require(receipt.get("image") == "ghcr.io/mesh-llm/mesh-llm-cuda-runner", "identity image mismatch")
    runtime = receipt["runtime"]
    catalog = decode(read_bytes(Path(__file__).resolve().parents[1] / "config/runner-image-families.json"))
    backend = next(item for item in catalog["backends"] if item["id"] == identity["backend_id"])
    require(runtime["family"] == {"environment": identity["environment"], "backend": backend["name"],
            "cuda_series": backend["cuda_series"], "rocm_version": backend["rocm_version"]}, "identity runtime family mismatch")
    require(runtime["source"] == {"mesh_revision": identity["mesh_llm_sha"],
            "runner_images_revision": identity["runner_images_sha"]}, "identity source mismatch")
    platform = {"os": "linux", "architecture": identity["platform"].split("/")[1]}
    require(receipt["platform"] == platform and runtime["platform"] == platform, "identity platform mismatch")
    require(receipt["backend_id"] == identity["backend_id"] and
            runtime["family"]["environment"] == identity["environment"], "identity family mismatch")
    verifier = runtime["verification"]["verifier_revision"]
    require(isinstance(verifier, str) and SHA.fullmatch(verifier), "invalid verifier SHA")
    descriptors = {key: oci.metadata_descriptor(receipt["oci"][key], allowed) for key, allowed in (
        ("root", oci.INDEX_TYPES | oci.MANIFEST_TYPES), ("manifest", oci.MANIFEST_TYPES), ("config", oci.CONFIG_TYPES))}
    layers = receipt["layers"]
    require(isinstance(layers, list) and 0 < len(layers) <= 4096, "invalid layer count")
    seen = {}
    for layer in layers:
        require(set(layer) == {"mediaType", "digest", "size", "compression"}, "invalid layer keys")
        descriptor = oci.descriptor(layer)
        number(descriptor["size"])
        text(descriptor["mediaType"])
        require(layer["compression"] == oci.COMPRESSION.get(layer["mediaType"], "unknown"), "layer compression mismatch")
        require(layer["digest"] not in seen or seen[layer["digest"]] == descriptor, "conflicting duplicate layer")
        seen[layer["digest"]] = descriptor
    total = number(sum(layer["size"] for layer in layers))
    compressed = number(sum(layer["size"] for layer in layers if layer["compression"] in {"gzip", "zstd"}))
    return {"verifier_sha": verifier, "identity_receipt_sha256": sha256(raw), "oci": descriptors, "layers": layers,
            "totals": {"layer_descriptor_bytes": total, "compressed_layer_descriptor_bytes": compressed,
                       "distinct_layer_digests": sorted(seen)}}


def create_receipt(role, env, metadata=None, identity_raw=None, cache_raw=None, state=None, now=None, cache_format="buildkit-rawjson-v1"):
    identity = identity_from_env(env)
    outcome = env.get("METRICS_OUTCOME") or "unknown"
    require(outcome in {"success", "failure", "cancelled", "skipped", "unknown"}, "invalid outcome")
    elapsed = None
    if state is not None:
        require(role == "verification" and isinstance(state, dict) and
                set(state) == {"outcome", "wrapper_elapsed_seconds"}, "invalid invocation state")
        outcome = state["outcome"]
        require(outcome in {"success", "failure"}, "invalid invocation state outcome")
        elapsed = number(state["wrapper_elapsed_seconds"], integer=False)
    elif role == "verification" and outcome not in {"skipped", "cancelled"}:
        # A shell failure before the invocation is not a failed Depot build.
        outcome = "unknown"
    elif role == "production" and outcome not in {"skipped", "unknown"}:
        if "METRICS_ELAPSED_SECONDS" in env:
            elapsed = optional_number(env["METRICS_ELAPSED_SECONDS"])
        else:
            start = optional_number(env.get("METRICS_STARTED_AT"))
            if start is not None:
                elapsed = number((int(time.time()) if now is None else now) - start, integer=False)
    if role == "production":
        build_id, project_id = env.get("METRICS_BUILD_ID") or None, env.get("METRICS_PROJECT_ID") or None
    elif metadata is None:
        build_id = project_id = None
    else:
        depot = decode(metadata).get("depot.build")
        require(isinstance(depot, dict), "missing depot.build metadata")
        build_id, project_id = depot.get("buildID"), depot.get("projectID")
    for value in (build_id, project_id):
        if value is not None:
            text(value)
    if outcome == "success":
        require(build_id is not None and project_id is not None, "successful invocation requires Depot IDs")
    if project_id is not None:
        require(project_id == env.get("DEPOT_PROJECT_ID"), "Depot project mismatch")
    verification = None
    if identity_raw is not None:
        require(role == "verification" and outcome == "success", "identity requires successful verification invocation")
        verification = verification_metrics(identity_raw, identity)
        require(verification["verifier_sha"] == env.get("METRICS_VERIFIER_SHA"), "verifier SHA mismatch")
    cache = None
    if cache_raw is not None:
        require(build_id is not None and project_id is not None, "cache evidence requires invocation IDs")
        cache = cache_proof(cache_raw, cache_format)
    content = optional_number(env.get("METRICS_CONTEXT_BYTES"))
    count = optional_number(env.get("METRICS_CONTEXT_FILES"))
    require((content is None) == (count is None), "partial context measurement")
    if outcome == "skipped":
        require(build_id is None and project_id is None and elapsed is None and verification is None and cache is None,
                "skipped invocation cannot contain invocation measurements")
        if role == "verification":
            require(content is None and count is None, "skipped verification cannot contain context measurements")
    return {"schema": 1, "type": "mesh-llm-runner-build-metrics", "identity": identity, "role": role,
            "outcome": outcome, "depot": {"build_id": build_id, "project_id": project_id, "execution_seconds": None},
            "wrapper_elapsed_seconds": elapsed, "context": {"content_bytes": content, "file_count": count, "transfer_seconds": None},
            "verification": verification, "cache_evidence": cache}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--role", choices=("production", "verification"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, help="Optional Depot metadata; absence allowed after failure")
    parser.add_argument("--identity", type=Path, help="Optional completed bound identity receipt")
    parser.add_argument("--state", type=Path, help="Optional invocation outcome and elapsed time")
    parser.add_argument("--cache-format", choices=("buildkit-rawjson-v1", "buildkit-plain-v1"), default="buildkit-rawjson-v1")
    parser.add_argument("--cache-log", type=Path, help="Explicit invocation-scoped rawjson stream; must exist if supplied")
    args = parser.parse_args()
    optional = lambda path: read_bytes(path) if path is not None and (path.exists() or path.is_symlink()) else None
    identity_raw = optional(args.identity)
    state_raw = optional(args.state)
    cache_raw = read_bytes(args.cache_log, MAX_CACHE) if args.cache_log else None
    receipt = create_receipt(args.role, os.environ, optional(args.metadata), identity_raw, cache_raw,
                             decode(state_raw) if state_raw is not None else None, cache_format=args.cache_format)
    raw = (json.dumps(receipt, indent=2, sort_keys=True, allow_nan=False) + "\n").encode()
    require(len(raw) <= MAX_JSON, "receipt exceeds 1 MiB")
    require(not args.output.exists(), "immutable receipt bundle already exists")
    args.output.mkdir(parents=True)
    if identity_raw is not None:
        (args.output / "identity.json").write_bytes(identity_raw)
    if cache_raw is not None:
        (args.output / ("cache.log" if args.cache_format == "buildkit-plain-v1" else "cache.jsonl")).write_bytes(cache_raw)
    (args.output / "receipt.json").write_bytes(raw)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(f"runner build metrics failed: {error}", file=sys.stderr)
        sys.exit(1)
