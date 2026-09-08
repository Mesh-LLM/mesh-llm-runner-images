#!/usr/bin/env python3
"""Bind exact-digest runtime observations to verified OCI metadata.

Run only after Dockerfile.verify succeeds against candidate.image@candidate.digest.
This receipt records that verification; it is not a signature or an admission rule.
"""

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

# Runtime inspection must not add bytecode files to the next Docker context.
sys.dont_write_bytecode = True


def sibling(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), Path(__file__).with_name(name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


identity = sibling("collect-runner-identity")
oci = sibling("measure-image-layers")
require = identity.require
exact_keys = identity.exact_keys
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


def digest(value):
    return isinstance(value, str) and DIGEST.fullmatch(value)


def read_json(path):
    require(path.stat().st_size <= oci.MAX_METADATA_BYTES, "identity metadata exceeds 16 MiB")
    return json.loads(path.read_bytes())


def validate_tools(tools, pins, platform, lean, browser):
    exact_keys(tools, ("node", "pnpm", "just", "rustc", "cargo", "sccache", "openai_npm", "playwright", "python"), "observed tools")
    exact_keys(tools["node"], ("version", "modules_abi"), "observed Node")
    node = tools["node"]
    require(isinstance(node["version"], str) and identity.VERSION.fullmatch(node["version"])
            and int(node["version"].split(".")[0]) == pins["common"]["node_major"]
            and isinstance(node["modules_abi"], str) and node["modules_abi"].isdigit(), "observed Node disagrees with pin/ABI schema")
    exact_keys(tools["pnpm"], ("version", "store_format"), "observed pnpm")
    require(tools["pnpm"]["version"] == pins["common"]["pnpm"] and isinstance(tools["pnpm"]["store_format"], str)
            and re.fullmatch(r"v[0-9]+", tools["pnpm"]["store_format"]), "observed pnpm disagrees with pin/store schema")
    require(tools["just"] == {"version": pins["common"]["just"]}, "observed just disagrees with pin")
    if lean:
        require(all(tools[key] is None for key in ("rustc", "cargo", "sccache", "openai_npm")), "lean compiler/AI observations must be null")
    else:
        exact_keys(tools["rustc"], ("release", "commit_hash", "host", "llvm_version"), "observed Rust")
        rust = tools["rustc"]
        require(rust["release"] == pins["full"]["rust"] and isinstance(rust["commit_hash"], str)
                and identity.SHA.fullmatch(rust["commit_hash"]), "observed Rust disagrees with pin/commit schema")
        require(isinstance(rust["host"], str) and rust["host"].startswith({"amd64": "x86_64-", "arm64": "aarch64-"}[platform["architecture"]])
                and "linux" in rust["host"] and isinstance(rust["llvm_version"], str) and rust["llvm_version"], "observed Rust host/LLVM mismatch")
        for name, pin in (("cargo", "rust"), ("sccache", "sccache"), ("openai_npm", "openai_npm")):
            require(tools[name] == {"version": pins["full"][pin]}, f"observed {name} disagrees with pin")
    if browser:
        exact_keys(tools["playwright"], ("version", "chromium_build"), "observed Playwright")
        require(tools["playwright"]["version"] == pins["browser"]["playwright"]
                and isinstance(tools["playwright"]["chromium_build"], str) and tools["playwright"]["chromium_build"].isdigit(), "observed Playwright disagrees with pin/build schema")
    else:
        require(tools["playwright"] is None, "unexpected observed Playwright")
    exact_keys(tools["python"], ("version", "abi", "runtime", "packages_sha256"), "observed Python")
    python = tools["python"]
    require(isinstance(python["version"], str) and identity.VERSION.fullmatch(python["version"])
            and isinstance(python["abi"], str) and python["abi"] and python["runtime"] == ("stdlib" if lean else "venv")
            and (python["packages_sha256"] is None if lean else digest(python["packages_sha256"])), "invalid observed Python identity")


def validate_candidate(candidate):
    exact_keys(candidate, ("schema", "type", "image", "environment", "backend", "mesh_revision",
                           "runner_images_revision", "platform", "digest", "child_digest"), "platform candidate")
    require(type(candidate["schema"]) is int and candidate["schema"] == 1
            and candidate["type"] == "mesh-llm-runner-image-platform-candidate", "unsupported platform candidate")
    require(isinstance(candidate["image"], str) and re.fullmatch(r"ghcr\.io/[a-z0-9][a-z0-9._-]*(?:/[a-z0-9][a-z0-9._-]*)+", candidate["image"]), "invalid candidate repository")
    require(candidate["environment"] in {"public", "self-hosted"}, "invalid candidate environment")
    for key in ("mesh_revision", "runner_images_revision"):
        require(isinstance(candidate[key], str) and identity.SHA.fullmatch(candidate[key]), "invalid candidate source revision")
    require(digest(candidate["digest"]) and digest(candidate["child_digest"]), "invalid candidate digest")
    exact_keys(candidate["platform"], ("os", "architecture"), "candidate platform")
    require(candidate["platform"]["os"] == "linux" and candidate["platform"]["architecture"] in {"amd64", "arm64"}, "unsupported candidate platform")
    backend = candidate["backend"]
    exact_keys(backend, ("id", "name", "cuda_series", "rocm_version"), "candidate backend")
    name = backend["name"]
    require(name in {"cpu", "vulkan", "cuda", "rocm", "web", "ui", "browser"}, "invalid candidate backend")
    if name == "cuda":
        require(isinstance(backend["id"], str) and re.fullmatch(r"cuda[0-9]+", backend["id"])
                and isinstance(backend["cuda_series"], str) and re.fullmatch(r"[0-9]+-[0-9]+", backend["cuda_series"]), "invalid CUDA family")
        require(backend["id"] == "cuda" + backend["cuda_series"].split("-")[0], "CUDA family/version mismatch")
    elif name == "rocm":
        require(isinstance(backend["id"], str) and re.fullmatch(r"rocm[0-9]+", backend["id"])
                and isinstance(backend["rocm_version"], str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", backend["rocm_version"]), "invalid ROCm family")
        require(backend["id"] == "rocm" + "".join(backend["rocm_version"].split(".")[:2]), "ROCm family/version mismatch")
    else:
        require(backend["id"] == name, "candidate backend id mismatch")
    require(name == "cuda" or backend["cuda_series"] is None, "unexpected CUDA version")
    require(name == "rocm" or backend["rocm_version"] is None, "unexpected ROCm version")
    require(name not in {"web", "ui", "browser"} or candidate["environment"] == "public", "unsupported browser/UI environment")
    require(name not in {"ui", "browser"} or candidate["platform"]["architecture"] == "amd64", "unsupported lean architecture")


def bind(runtime, candidate, root_raw, manifest_raw, expected_directory, verifier_revision):
    validate_candidate(candidate)
    require(isinstance(verifier_revision, str) and identity.SHA.fullmatch(verifier_revision), "invalid verifier revision")
    pins, policy = identity.read_policy(expected_directory)
    exact_keys(runtime, ("schema", "type", "platform", "family", "source", "verification", "expected_tools",
                         "tools", "dependencies", "cache"), "runtime identity")
    require(type(runtime["schema"]) is int and runtime["schema"] == 1
            and runtime["type"] == "mesh-llm-runner-runtime-identity", "unsupported runtime identity")
    require(runtime["platform"] == candidate["platform"], "runtime/candidate platform mismatch")
    backend = candidate["backend"]
    require(runtime["family"] == {"environment": candidate["environment"], "backend": backend["name"],
                                  "cuda_series": backend["cuda_series"], "rocm_version": backend["rocm_version"]}, "runtime/candidate family mismatch")
    require(runtime["source"] == {key: candidate[key] for key in ("mesh_revision", "runner_images_revision")}, "runtime/candidate source mismatch")
    require(runtime["verification"] == {"verifier_revision": verifier_revision,
            "tool_pins_sha256": identity.digest_json(pins), "cache_policy_sha256": identity.digest_json(policy)}, "runtime verification expectations mismatch")
    lean, browser = backend["name"] in {"ui", "browser"}, backend["name"] in {"web", "browser"}
    require(runtime["expected_tools"] == {**pins["common"], **{name: None if lean else value for name, value in pins["full"].items()},
            "playwright": pins["browser"]["playwright"] if browser else None}, "runtime expected tools mismatch")
    validate_tools(runtime["tools"], pins, runtime["platform"], lean, browser)
    dependencies = runtime["dependencies"]
    exact_keys(dependencies, ("kind", "index_sha256", "python_lock_sha256", "pnpm_lifecycle"), "runtime dependency identity")
    kind = "ui" if lean else "full"
    require(dependencies["kind"] == kind and digest(dependencies["index_sha256"])
            and dependencies["pnpm_lifecycle"] == policy["pnpm_lifecycle"][kind], "runtime dependency scope mismatch")
    require(dependencies["python_lock_sha256"] == (None if lean else identity.digest_bytes((expected_directory / "python-requirements.lock").read_bytes())), "runtime Python lock mismatch")
    require(runtime["cache"] == identity.cache_identity(runtime["platform"], runtime["tools"], dependencies, policy), "runtime cache fingerprint mismatch")

    require(len(root_raw) <= oci.MAX_METADATA_BYTES and len(manifest_raw) <= oci.MAX_METADATA_BYTES, "OCI metadata exceeds 16 MiB")
    root = oci.decode(root_raw)
    root_descriptor = oci.metadata_descriptor({"mediaType": root.get("mediaType"), "digest": candidate["digest"], "size": len(root_raw)}, oci.INDEX_TYPES | oci.MANIFEST_TYPES)
    oci.decode(root_raw, root_descriptor)
    require(root.get("schemaVersion") == 2, "unsupported root schema")
    selected = root_descriptor
    if root_descriptor["mediaType"] in oci.INDEX_TYPES:
        require(isinstance(root.get("manifests"), list), "index has no manifest descriptors")
        runnable = []
        for entry in root["manifests"]:
            oci.metadata_descriptor(entry, oci.MANIFEST_TYPES)
            require(isinstance(entry.get("annotations", {}), dict), "invalid manifest annotations")
            if entry.get("platform") == {"os": "unknown", "architecture": "unknown"} and entry.get("annotations", {}).get("vnd.docker.reference.type") == "attestation-manifest":
                continue
            require(oci.matches_platform(entry.get("platform"), candidate["platform"]), "unexpected platform in platform candidate index")
            require(entry.get("annotations", {}).get("vnd.docker.reference.type") != "attestation-manifest", "attestation cannot be a runtime image")
            runnable.append(entry)
        require(len(runnable) == 1, "expected exactly one runnable platform manifest")
        selected = oci.metadata_descriptor(runnable[0], oci.MANIFEST_TYPES)
    require(selected["digest"] == candidate["child_digest"], "candidate child digest mismatch")
    manifest = oci.decode(manifest_raw, selected)
    require(manifest.get("schemaVersion") == 2 and manifest.get("mediaType") == selected["mediaType"], "unsupported image manifest")
    require(not manifest.get("artifactType") and not manifest.get("subject"), "artifact is not a runnable image")
    config = oci.metadata_descriptor(manifest.get("config"), oci.CONFIG_TYPES)
    require(isinstance(manifest.get("layers"), list) and manifest["layers"], "image has no layers")
    layers = [{**oci.descriptor(entry), "compression": oci.COMPRESSION.get(entry.get("mediaType"), "unknown")} for entry in manifest["layers"]]
    return {"schema": 1, "type": "mesh-llm-runner-image-identity", "image": candidate["image"],
            "platform": candidate["platform"], "backend_id": backend["id"],
            "oci": {"root": root_descriptor, "manifest": selected, "config": config},
            "runtime": runtime, "layers": layers,
            "scope": "Runtime observations from exact-digest verification. OCI descriptor bytes are not pull savings. Receipt admission requires trusted workflow provenance."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("runtime", "candidate", "index", "manifest", "expected-directory", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--verifier-revision", required=True)
    args = parser.parse_args()
    for path in (args.index, args.manifest):
        require(path.stat().st_size <= oci.MAX_METADATA_BYTES, "OCI metadata exceeds 16 MiB")
    result = bind(read_json(args.runtime), read_json(args.candidate), args.index.read_bytes(), args.manifest.read_bytes(), args.expected_directory, args.verifier_revision)
    args.output.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as error:
        raise SystemExit(f"runner identity binding failed: {error}") from error
