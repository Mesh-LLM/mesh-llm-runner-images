#!/usr/bin/env python3
"""Retain and admit a complete verified cohort. Downloaded inputs are data only."""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import importlib.util
import io
import json
import re
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "Mesh-LLM/mesh-llm-runner-images"
WORKFLOW = ".github/workflows/build-and-push.yml"
IMAGE = "ghcr.io/mesh-llm/mesh-llm-cuda-runner"
MAX_BYTES = 32 * 1024 * 1024
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
spec = importlib.util.spec_from_file_location("cohort_binder", ROOT / "scripts/bind-runner-identity.py")
binder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binder)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact(value, keys, label):
    require(isinstance(value, dict) and set(value) == set(keys), f"invalid {label} fields")


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def decode(raw):
    require(len(raw) <= MAX_BYTES, "cohort data exceeds 32 MiB")
    return json.loads(raw, object_pairs_hook=unique_pairs)


def read_bytes(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_BYTES,
            f"expected bounded regular data file: {path}")
    return path.read_bytes()


def read(path):
    return decode(read_bytes(path))


def raw(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def matrices():
    return decode(subprocess.check_output(["bash", str(ROOT / "scripts/generate-workflow-matrices.sh")]))


def backend(row):
    return {"id": row["backend_id"], "name": row["backend_name"],
            "cuda_series": None if row["cuda_series"] == "none" else row["cuda_series"],
            "rocm_version": None if row["rocm_version"] == "none" else row["rocm_version"]}


def platform_key(environment, backend_id, architecture):
    return f"{environment}-{backend_id}-{architecture}"


def expected_platforms(matrix):
    return {platform_key(row["environment"], row["backend_id"], arch): (row, arch)
            for row in matrix["family_matrix"]["include"] for arch in row["architectures"].split(",")}


def validate_origin(origin):
    exact(origin, ("repository", "repository_id", "workflow_id", "workflow_path", "run_id", "run_attempt",
                   "event", "runner_images_revision", "mesh_revision", "timestamp"), "cohort origin")
    require(origin["repository"] == REPOSITORY and origin["workflow_path"] == WORKFLOW, "untrusted cohort workflow")
    require(origin["event"] in {"push", "schedule", "workflow_dispatch"}, "untrusted cohort event")
    for key in ("repository_id", "workflow_id", "run_id", "run_attempt"):
        require(type(origin[key]) is int and origin[key] > 0, f"invalid origin {key}")
    for key in ("runner_images_revision", "mesh_revision"):
        require(isinstance(origin[key], str) and SHA.fullmatch(origin[key]), f"invalid origin {key}")
    require(isinstance(origin["timestamp"], str) and re.fullmatch(r"[0-9]{14}", origin["timestamp"]), "invalid cohort timestamp")
    datetime.strptime(origin["timestamp"], "%Y%m%d%H%M%S")


def index_sources(row, catalog):
    if row["backend_name"] == "mixed":
        return next(index["sources"] for index in catalog["indexes"] if index["artifact"] == row["artifact"])
    return [{"environment": row["environment"], "backend_id": row["backend_id"], "architecture": arch}
            for arch in row["architectures"].split(",")]


def validate_index(candidate, row, origin, children):
    exact(candidate, ("schema", "type", "image", "environment", "backend", "mesh_revision", "runner_images_revision", "digest", "children"), "index candidate")
    require(type(candidate["schema"]) is int and candidate["schema"] == 1
            and candidate["type"] == "mesh-llm-runner-image-candidate" and candidate["image"] == IMAGE
            and candidate["environment"] == row["environment"] and candidate["backend"] == backend(row)
            and all(candidate[name] == origin[name] for name in ("mesh_revision", "runner_images_revision"))
            and isinstance(candidate["digest"], str) and DIGEST.fullmatch(candidate["digest"]), "index differs from cohort/catalog")
    require(candidate["children"] == sorted(children, key=lambda child: child["architecture"]), "index children differ from verified platforms")
    require(len({c["digest"] for c in children}) == len(children), "duplicate index child digests")
    require(sorted(c["architecture"] for c in children) == sorted(row["architectures"].split(",")), "index architecture set differs from catalog")


def validate(cohort):
    exact(cohort, ("schema", "type", "image", "origin", "catalog_sha256", "candidates", "platforms"), "cohort")
    require(type(cohort["schema"]) is int and cohort["schema"] == 1 and cohort["type"] == "mesh-llm-runner-staged-cohort", "invalid cohort schema")
    require(cohort["image"] == IMAGE, "unexpected cohort image")
    origin = cohort["origin"]
    validate_origin(origin)
    catalog = read(ROOT / "config/runner-image-families.json")
    require(cohort["catalog_sha256"] == digest(raw(catalog)), "staged catalog differs from current catalog")
    matrix = matrices()
    platforms = expected_platforms(matrix)
    require(isinstance(cohort["platforms"], dict) and set(cohort["platforms"]) == set(platforms), "incomplete or extra cohort platforms")
    for key, (row, arch) in platforms.items():
        entry = cohort["platforms"][key]
        exact(entry, ("candidate", "receipt", "index_base64", "manifest_base64"), "platform evidence")
        candidate = entry["candidate"]
        binder.validate_candidate(candidate)
        require(candidate["image"] == IMAGE and candidate["environment"] == row["environment"]
                and candidate["backend"] == backend(row) and candidate["platform"] == {"os": "linux", "architecture": arch}
                and all(candidate[name] == origin[name] for name in ("mesh_revision", "runner_images_revision")), "platform differs from cohort/catalog")
        root_raw = base64.b64decode(entry["index_base64"], validate=True)
        manifest_raw = base64.b64decode(entry["manifest_base64"], validate=True)
        receipt = binder.bind(entry["receipt"]["runtime"], candidate, root_raw, manifest_raw,
                              ROOT / "config", origin["runner_images_revision"])
        require(entry["receipt"] == receipt, "retained receipt differs from independently bound evidence")
    rows = matrix["promotion_matrix"]["include"]
    require(isinstance(cohort["candidates"], dict) and set(cohort["candidates"]) == {r["artifact"] for r in rows}, "incomplete or extra cohort indexes")
    for row in rows:
        sources = index_sources(row, catalog)
        children = [{"os": "linux", "architecture": source["architecture"], "digest": cohort["platforms"][platform_key(**source)]["candidate"]["child_digest"]}
                    for source in sources]
        validate_index(cohort["candidates"][row["artifact"]], row, origin, children)
    return matrix


def gh_json(endpoint):
    return decode(subprocess.check_output(["gh", "api", "--method", "GET", endpoint]))


def validate_run(run, workflow, run_id, attempt, *, allow_running=False):
    require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0, "invalid staged run/attempt")
    repository = run.get("repository", {})
    head_repository = run.get("head_repository", {})
    require(repository.get("full_name") == REPOSITORY and head_repository.get("full_name") == REPOSITORY
            and type(repository.get("id")) is int and repository["id"] > 0 and repository["id"] == head_repository.get("id"), "staged run repository mismatch")
    require(run.get("id") == run_id and run.get("run_attempt") == attempt, "staged run attempt mismatch")
    require(run.get("head_branch") == "main" and run.get("path") == WORKFLOW, "staged run must use main workflow")
    require(workflow.get("path") == WORKFLOW and type(workflow.get("id")) is int
            and workflow["id"] > 0 and run.get("workflow_id") == workflow["id"], "staged workflow ID mismatch")
    require(run.get("event") in {"push", "schedule", "workflow_dispatch"}, "untrusted staged event")
    require(isinstance(run.get("head_sha"), str) and SHA.fullmatch(run["head_sha"]), "invalid staged source revision")
    if allow_running:
        require(run.get("status") == "in_progress" and run.get("conclusion") is None, "seal requires current running attempt")
    else:
        require(run.get("status") == "completed" and run.get("conclusion") == "success", "staged attempt has not completed successfully")


def validate_artifact(artifact, run, now):
    require(type(artifact.get("id")) is int and artifact["id"] > 0, "invalid artifact ID")
    require(artifact.get("name") == f"staged-cohort-{run['id']}-{run['run_attempt']}", "artifact attempt/name mismatch")
    require(artifact.get("expired") is False and datetime.fromisoformat(artifact["expires_at"].replace("Z", "+00:00")) > now, "staged artifact expired")
    require(type(artifact.get("size_in_bytes")) is int and 0 < artifact["size_in_bytes"] <= MAX_BYTES, "invalid artifact size")
    require(isinstance(artifact.get("digest"), str) and DIGEST.fullmatch(artifact["digest"]), "artifact lacks content digest")
    source = artifact.get("workflow_run", {})
    require(source.get("id") == run["id"] and source.get("repository_id") == run["repository"]["id"]
            and source.get("head_repository_id") == run["repository"]["id"] and source.get("head_branch") == "main"
            and source.get("head_sha") == run["head_sha"], "artifact origin mismatch")


def unpack_archive(archive, artifact):
    require(len(archive) == artifact["size_in_bytes"] and digest(archive) == artifact["digest"], "artifact archive digest/size mismatch")
    with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
        entries = bundle.infolist()
        require(len(entries) == 1 and entries[0].filename == "staged-cohort.json", "artifact must contain only staged-cohort.json")
        entry = entries[0]
        mode = entry.external_attr >> 16
        require(not entry.is_dir() and stat.S_IFMT(mode) in (0, stat.S_IFREG)
                and not entry.flag_bits & 1 and entry.file_size <= MAX_BYTES, "unsafe cohort archive entry")
        return decode(bundle.read(entry))


def match_origin(cohort, run):
    origin = cohort["origin"]
    require(all(origin[key] == value for key, value in {
        "repository_id": run["repository"]["id"], "workflow_id": run["workflow_id"],
        "run_id": run["id"], "run_attempt": run["run_attempt"], "event": run["event"],
        "runner_images_revision": run["head_sha"],
    }.items()), "cohort origin differs from GitHub run")


def fetch(run_id, attempt):
    require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0, "invalid staged run/attempt")
    # Exact attempt endpoint, not the latest attempt's conclusion.
    prefix = f"repos/{REPOSITORY}/actions"
    run = gh_json(f"{prefix}/runs/{run_id}/attempts/{attempt}")
    workflow = gh_json(f"{prefix}/workflows/build-and-push.yml")
    validate_run(run, workflow, run_id, attempt)
    artifacts = []
    page = 1
    while True:
        result = gh_json(f"{prefix}/runs/{run_id}/artifacts?per_page=100&page={page}")
        require(isinstance(result.get("artifacts"), list) and page <= 100, "invalid artifact listing")
        artifacts.extend(result["artifacts"])
        if len(result["artifacts"]) < 100:
            break
        page += 1
    matches = [item for item in artifacts if item.get("name") == f"staged-cohort-{run_id}-{attempt}"]
    require(len(matches) == 1, "expected one retained artifact for the exact staged attempt")
    # Re-read immutable artifact ID before downloading, including expiry/digest.
    artifact = gh_json(f"{prefix}/artifacts/{matches[0]['id']}")
    require(artifact.get("id") == matches[0]["id"], "artifact ID mismatch")
    validate_artifact(artifact, run, datetime.now(timezone.utc))
    with tempfile.TemporaryFile() as destination:
        subprocess.run(["gh", "api", f"{prefix}/artifacts/{artifact['id']}/zip"], stdout=destination, check=True)
        require(destination.tell() <= MAX_BYTES, "artifact archive exceeds 32 MiB")
        destination.seek(0)
        cohort = unpack_archive(destination.read(), artifact)
    validate(cohort)
    match_origin(cohort, run)
    return cohort


def seal(directory, run_id, attempt, mesh_revision, timestamp):
    require(type(run_id) is int and run_id > 0 and type(attempt) is int and attempt > 0, "invalid staged run/attempt")
    prefix = f"repos/{REPOSITORY}/actions"
    run = gh_json(f"{prefix}/runs/{run_id}/attempts/{attempt}")
    workflow = gh_json(f"{prefix}/workflows/build-and-push.yml")
    validate_run(run, workflow, run_id, attempt, allow_running=True)
    # Sealing is called only by the successful dependency chain in this run.
    import os
    require(os.environ.get("GITHUB_RUN_ID") == str(run_id) and os.environ.get("GITHUB_RUN_ATTEMPT") == str(attempt)
            and os.environ.get("GITHUB_SHA") == run["head_sha"]
            and os.environ.get("GITHUB_WORKFLOW_REF") == f"{REPOSITORY}/{WORKFLOW}@refs/heads/main", "seal is not executing in the source attempt")
    matrix = matrices()
    cohort = {"schema": 1, "type": "mesh-llm-runner-staged-cohort", "image": IMAGE,
              "catalog_sha256": digest(raw(read(ROOT / "config/runner-image-families.json"))),
              "origin": {"repository": REPOSITORY, "repository_id": run["repository"]["id"],
                         "workflow_id": run["workflow_id"], "workflow_path": WORKFLOW,
                         "run_id": run_id, "run_attempt": attempt, "event": run["event"],
                         "runner_images_revision": run["head_sha"], "mesh_revision": mesh_revision, "timestamp": timestamp},
              "candidates": {}, "platforms": {}}
    for row in matrix["promotion_matrix"]["include"]:
        name = row["artifact"]
        cohort["candidates"][name] = read(directory / f"{name}-{attempt}" / f"{name}.json")
    for key in expected_platforms(matrix):
        evidence = directory / f"runner-identity-{key}-{attempt}"
        cohort["platforms"][key] = {"candidate": read(directory / f"candidate-platform-{key}-{attempt}" / f"candidate-platform-{key}.json"),
                                    "receipt": read(evidence / "identity.json"),
                                    "index_base64": base64.b64encode(read_bytes(evidence / "index.json")).decode(),
                                    "manifest_base64": base64.b64encode(read_bytes(evidence / "manifest.json")).decode()}
    validate(cohort)
    return cohort


def export(cohort, directory):
    matrix = validate(cohort)
    directory.mkdir(parents=True, exist_ok=False)
    for name, value in cohort["candidates"].items():
        (directory / (name + ".json")).write_bytes(raw(value) + b"\n")
    (directory / "promotion-matrix.json").write_bytes(raw(matrix["promotion_matrix"]) + b"\n")
    (directory / "origin.json").write_bytes(raw(cohort["origin"]) + b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    for command in ("seal", "fetch"):
        sub = subs.add_parser(command)
        sub.add_argument("--run-id", type=int, required=True)
        sub.add_argument("--attempt", type=int, required=True)
        sub.add_argument("--output", type=Path, required=True)
        if command == "seal":
            sub.add_argument("--artifacts", type=Path, required=True)
            sub.add_argument("--mesh-revision", required=True)
            sub.add_argument("--timestamp", required=True)
    for command in ("validate", "export"):
        sub = subs.add_parser(command)
        sub.add_argument("--cohort", type=Path, required=True)
        if command == "export":
            sub.add_argument("--directory", type=Path, required=True)
    args = parser.parse_args()
    if args.command in {"seal", "fetch"}:
        cohort = fetch(args.run_id, args.attempt) if args.command == "fetch" else seal(args.artifacts, args.run_id, args.attempt, args.mesh_revision, args.timestamp)
        payload = raw(cohort) + b"\n"
        require(len(payload) <= MAX_BYTES, "cohort exceeds 32 MiB")
        args.output.write_bytes(payload)
    elif args.command == "export":
        export(read(args.cohort), args.directory)
    else:
        validate(read(args.cohort))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        sys.exit(f"runner cohort: {error}")
