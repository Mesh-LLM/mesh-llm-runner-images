import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

repository = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("binder", repository / "scripts/bind-runner-identity.py")
binder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(binder)
SOURCE, RUNNER, VERIFIER = "1" * 40, "2" * 40, "3" * 40
INDEX = "application/vnd.oci.image.index.v1+json"
MANIFEST = "application/vnd.oci.image.manifest.v1+json"
CONFIG = "application/vnd.oci.image.config.v1+json"
LAYER = "application/vnd.oci.image.layer.v1.tar+gzip"


def raw(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def descriptor(value, media_type):
    return {"mediaType": media_type, "digest": "sha256:" + hashlib.sha256(value).hexdigest(), "size": len(value)}


class IdentityFixtures(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.expected = self.root / "trusted"
        self.expected.mkdir()
        for name in ("tool-pins.json", "cache-policy.json"):
            shutil.copyfile(repository / "config" / name, self.expected / name)
        (self.expected / "python-requirements.lock").write_text("example-package==1.2.3\n")
        self.pins, self.policy = binder.identity.read_policy(self.expected)

    def fixture(self, backend="cpu", architecture="amd64", indexed=True, attestation=False):
        lean, browser = backend in {"ui", "browser"}, backend in {"web", "browser"}
        common, full = self.pins["common"], self.pins["full"]
        platform = {"os": "linux", "architecture": architecture}
        family = {"id": backend, "name": backend, "cuda_series": None, "rocm_version": None}
        if backend == "cuda": family.update(id="cuda12", cuda_series="12-9")
        if backend == "rocm": family.update(id="rocm72", rocm_version="7.2.3")
        tools = {
            "node": {"version": str(common["node_major"]) + ".0.0", "modules_abi": "137"},
            "pnpm": {"version": common["pnpm"], "store_format": "v10"},
            "just": {"version": common["just"]},
            "rustc": None if lean else {"release": full["rust"], "commit_hash": "4" * 40,
                "host": ("x86_64" if architecture == "amd64" else "aarch64") + "-unknown-linux-gnu", "llvm_version": "22.1.0"},
            "cargo": None if lean else {"version": full["rust"]},
            "sccache": None if lean else {"version": full["sccache"]},
            "openai_npm": None if lean else {"version": full["openai_npm"]},
            "playwright": {"version": self.pins["browser"]["playwright"], "chromium_build": "1234"} if browser else None,
            "python": {"version": "3.12.3", "abi": "cpython-312-linux-gnu", "runtime": "stdlib" if lean else "venv",
                "packages_sha256": None if lean else "sha256:" + "5" * 64},
        }
        dependencies = {"kind": "ui" if lean else "full", "index_sha256": "sha256:" + "6" * 64,
            "python_lock_sha256": None if lean else binder.identity.digest_bytes((self.expected / "python-requirements.lock").read_bytes()),
            "pnpm_lifecycle": "onnx-skip" if lean else "default"}
        runtime = {"schema": 1, "type": "mesh-llm-runner-runtime-identity", "platform": platform,
            "family": {"environment": "public", **{key: family[key] for key in ("cuda_series", "rocm_version")}, "backend": backend},
            "source": {"mesh_revision": SOURCE, "runner_images_revision": RUNNER},
            "verification": {"verifier_revision": VERIFIER, "tool_pins_sha256": binder.identity.digest_json(self.pins),
                "cache_policy_sha256": binder.identity.digest_json(self.policy)},
            "expected_tools": {**common, **{name: None if lean else value for name, value in full.items()},
                "playwright": self.pins["browser"]["playwright"] if browser else None},
            "tools": tools, "dependencies": dependencies,
            "cache": binder.identity.cache_identity(platform, tools, dependencies, self.policy)}
        config = descriptor(raw({**platform, "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "7" * 64]}}), CONFIG)
        manifest = {"schemaVersion": 2, "mediaType": MANIFEST, "config": config, "layers": [descriptor(b"fixture layer", LAYER)]}
        manifest_raw = raw(manifest)
        child = descriptor(manifest_raw, MANIFEST)
        index = {"schemaVersion": 2, "mediaType": INDEX, "manifests": [{**child, "platform": platform}]}
        if attestation:
            index["manifests"].append({**descriptor(b"attestation", MANIFEST),
                "platform": {"os": "unknown", "architecture": "unknown"},
                "annotations": {"vnd.docker.reference.type": "attestation-manifest"}})
        root_raw = raw(index) if indexed else manifest_raw
        candidate = {"schema": 1, "type": "mesh-llm-runner-image-platform-candidate",
            "image": "ghcr.io/mesh-llm/mesh-llm-cuda-runner", "environment": "public", "backend": family,
            "mesh_revision": SOURCE, "runner_images_revision": RUNNER, "platform": platform,
            "digest": descriptor(root_raw, INDEX if indexed else MANIFEST)["digest"], "child_digest": child["digest"]}
        return {"runtime": runtime, "candidate": candidate, "root_raw": root_raw, "manifest_raw": manifest_raw}

    def bind(self, fixture):
        return binder.bind(**fixture, expected_directory=self.expected, verifier_revision=VERIFIER)

    def reject(self, fixture, message=None):
        context = self.assertRaisesRegex(ValueError, message) if message else self.assertRaises((ValueError, KeyError, TypeError))
        with context:
            self.bind(fixture)

    def refresh_cache(self, fixture):
        runtime = fixture["runtime"]
        runtime["cache"] = binder.identity.cache_identity(runtime["platform"], runtime["tools"], runtime["dependencies"], self.policy)

    def update_index(self, fixture, value):
        fixture["root_raw"] = raw(value)
        fixture["candidate"]["digest"] = descriptor(fixture["root_raw"], INDEX)["digest"]

    def update_manifest(self, fixture, value):
        fixture["manifest_raw"] = raw(value)
        index = json.loads(fixture["root_raw"])
        index["manifests"][0].update(descriptor(fixture["manifest_raw"], MANIFEST))
        fixture["candidate"]["child_digest"] = index["manifests"][0]["digest"]
        self.update_index(fixture, index)

