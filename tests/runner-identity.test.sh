#!/usr/bin/env bash
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
python3 -B - "$repository_root" <<'PY'
import copy
import hashlib
import importlib.util
import json
import re
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

repository = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("identity", repository / "scripts/collect-runner-identity.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
SOURCE, RUNNER, VERIFIER = "1" * 40, "2" * 40, "3" * 40


def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def fixture(root, backend="cpu", source=SOURCE):
    expected_dir = root / "trusted"
    expected_dir.mkdir()
    for name in ("tool-pins.json", "cache-policy.json"):
        shutil.copyfile(repository / "config" / name, expected_dir / name)
    write(expected_dir / "python-requirements.lock", "example-package==1.2.3\n")
    expected = dict(environment="public", backend=backend, mesh_revision=source,
                    cuda_series="none", rocm_version="none", runner_images_revision=RUNNER,
                    playwright_version="1.62.1" if backend in {"web", "browser"} else "none")
    stamps = {"mesh-runner-environment": "public", "mesh-runner-backend": backend, "mesh-llm-revision": source,
              "mesh-runner-images-revision": RUNNER, "mesh-runner-cuda-series": "none", "mesh-runner-rocm-version": "none"}
    if backend in {"ui", "browser"}:
        stamps.update({"mesh-runner-node-major": "24", "mesh-runner-pnpm-version": "10.34.5"})
    if backend in {"web", "browser"}:
        stamps.update({"mesh-runner-playwright-version": "1.62.1", "mesh-runner-chromium-build": "chromium-1234"})
        (root / "opt/ms-playwright/chromium-1234").mkdir(parents=True)
    for name, value in stamps.items():
        write(root / "etc" / name, value + "\n")
    manifests = root / "opt/mesh-llm/manifests"
    files = {"crates/mesh-llm-ui/package.json": "{}\n", "crates/mesh-llm-ui/pnpm-lock.yaml": "lockfileVersion: 9\n"}
    if backend not in {"ui", "browser"}:
        files["Cargo.toml"] = "[workspace]\n"
        (root / "opt/mesh-llm/venv").mkdir(parents=True)
        write(root / "etc/mesh-runner-python-requirements.lock", "example-package==1.2.3\n")
        write(root / "home/runner/externals/node24/lib/node_modules/openai/package.json", '{"version":"7.5.0"}')
    entries = []
    for name, content in files.items():
        write(manifests / name, content)
        entries.append({"path": name, "sha256": hashlib.sha256(content.encode()).hexdigest()})
    write(manifests / "dependency-index.json", json.dumps({"schema": 1, "files": entries}))
    write(manifests / "manifest-index.json", json.dumps({"profile": "public", "source_revision": source,
          "manifests": [{**entry, "ecosystem": "fixture"} for entry in entries]}))
    write(manifests / "source-revision.txt", source + "\n")
    write(manifests / "profile.txt", "public\n")
    (root / "home/runner/.local/share/pnpm/store/v10").mkdir(parents=True)
    return expected_dir, expected


def observe(arguments):
    name = Path(arguments[0]).name
    if name == "uname": return "Linux x86_64\n"
    if name == "node":
        if "playwright" in arguments[-1]: return '{"version":"1.62.1","chromium_build":"1234"}\n'
        return '{"version":"24.18.0","modules_abi":"137","platform":"linux","architecture":"x64"}\n'
    if name == "pnpm": return "10.34.5\n" if arguments[1] == "--version" else "/home/runner/.local/share/pnpm/store/v10\n"
    if name == "just": return "just 1.57.0\n"
    if name == "rustc": return "rustc 1.98.1 (hash date)\nbinary: rustc\ncommit-hash: " + "4" * 40 + "\ncommit-date: 2026-08-20\nhost: x86_64-unknown-linux-gnu\nrelease: 1.98.1\nLLVM version: 22.1.0\n"
    if name == "cargo": return "cargo 1.98.1 (hash date)\n"
    if name == "sccache": return "sccache 0.16.0\n"
    if name in {"python", "python3"}:
        if arguments[1:4] == ["-m", "pip", "check"]: return "No broken requirements found.\n"
        return '{"version":"3.12.3","abi":"cpython-312-x86_64-linux-gnu","packages":{"example-package":"1.2.3","pip":"24.0"}}\n'
    raise AssertionError(arguments)


def collect(root, expected_dir, expected, observer=observe):
    environment = {"ONNXRUNTIME_NODE_INSTALL": "skip"} if expected["backend"] in {"ui", "browser"} else {}
    return module.collect_identity(expected_dir, expected, VERIFIER, root=root, observe=observer,
                                   environ=environment, which=lambda _: None)


class IdentityTests(unittest.TestCase):
    def test_full_and_lean_observations(self):
        for backend in ("cpu", "ui", "browser", "web"):
            with self.subTest(backend=backend), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory, expected = fixture(root, backend)
                receipt = collect(root, directory, expected)
                self.assertEqual(receipt["type"], "mesh-llm-runner-runtime-identity")
                self.assertEqual(receipt["tools"]["pnpm"]["version"], "10.34.5")
                self.assertNotIn("image", receipt)
                if backend in {"ui", "browser"}:
                    for tool in ("rustc", "cargo", "sccache", "openai_npm"):
                        self.assertIsNone(receipt["tools"][tool])
                    self.assertIsNone(receipt["dependencies"]["python_lock_sha256"])
                    self.assertIsNone(receipt["cache"]["input_fingerprints"]["sccache"])
                else:
                    self.assertEqual(receipt["tools"]["rustc"]["release"], "1.98.1")

    def test_wrong_actual_tool_fails_even_when_stamp_and_pin_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root, "browser")
            def wrong(arguments):
                if Path(arguments[0]).name == "pnpm" and arguments[1] == "--version": return "10.34.4\n"
                return observe(arguments)
            with self.assertRaisesRegex(ValueError, "pnpm"):
                collect(root, directory, expected, wrong)
            write(root / "etc/mesh-runner-pnpm-version", "10.34.4\n")
            with self.assertRaisesRegex(ValueError, "pnpm"):
                collect(root, directory, expected)

    def test_mismatched_rust_just_browser_and_lean_presence_fail(self):
        cases = [("cpu", "rustc", "rustc 1.98.0\nrelease: 1.98.0\n", "Rust"),
                 ("cpu", "just", "just 1.56.0\n", "just"),
                 ("browser", "node", '{"version":"1.62.0","chromium_build":"1234"}', "Playwright")]
        for backend, name, response, error in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory, expected = fixture(root, backend)
                def wrong(arguments):
                    if Path(arguments[0]).name == name and (name != "node" or "playwright" in arguments[-1]): return response
                    return observe(arguments)
                with self.assertRaisesRegex(ValueError, error): collect(root, directory, expected, wrong)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root, "ui")
            with self.assertRaisesRegex(ValueError, "compiler tools"):
                module.collect_identity(directory, expected, VERIFIER, root=root, observe=observe,
                        environ={"ONNXRUNTIME_NODE_INSTALL": "skip"}, which=lambda _: "/unexpected/cargo")
            write(root / "home/runner/externals/node24/lib/node_modules/openai/package.json", '{"version":"7.5.0"}')
            with self.assertRaisesRegex(ValueError, "OpenAI"):
                collect(root, directory, expected)

    def test_stale_or_unsafe_dependency_inputs_fail(self):
        for mutation in ("stale", "unsafe", "symlink"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory, expected = fixture(root)
                manifests = root / "opt/mesh-llm/manifests"
                if mutation == "stale": write(manifests / "Cargo.toml", "changed")
                elif mutation == "symlink":
                    (manifests / "Cargo.toml").unlink()
                    (manifests / "Cargo.toml").symlink_to(directory / "tool-pins.json")
                else:
                    index = json.loads((manifests / "dependency-index.json").read_text())
                    index["files"][0]["path"] = "../escape"
                    write(manifests / "dependency-index.json", json.dumps(index))
                with self.assertRaises(ValueError): collect(root, directory, expected)

    def test_missing_audited_ui_configuration_fails(self):
        for path in (".npmrc", "pnpm-workspace.yaml", "crates/mesh-llm-ui/.npmrc",
                     "crates/mesh-llm-ui/pnpm-workspace.yaml"):
            with self.subTest(path=path), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory, expected = fixture(root, "ui")
                audit_path = root / "opt/mesh-llm/manifests/manifest-index.json"
                audit = json.loads(audit_path.read_text())
                audit["manifests"].append({"path": path, "sha256": "a" * 64, "ecosystem": "node"})
                write(audit_path, json.dumps(audit))
                with self.assertRaisesRegex(ValueError, "source audit input missing"):
                    collect(root, directory, expected)

    def test_unindexed_payload_files_and_symlinks_fail(self):
        for backend, mutation in (("cpu", "file"), ("ui", "file"), ("cpu", "file_symlink"),
                                  ("ui", "directory_symlink"), ("ui", "node_modules")):
            with self.subTest(backend=backend, mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory, expected = fixture(root, backend)
                manifests = root / "opt/mesh-llm/manifests"
                if mutation == "file": write(manifests / ".npmrc", "auto-install-peers=false\n")
                elif mutation == "file_symlink": (manifests / ".npmrc").symlink_to(directory / "tool-pins.json")
                elif mutation == "directory_symlink": (manifests / "extra").symlink_to(directory, target_is_directory=True)
                else: write(manifests / "crates/mesh-llm-ui/node_modules/package/index.js", "unexpected payload")
                with self.assertRaisesRegex(ValueError, "unindexed|symlink"):
                    collect(root, directory, expected)

    def test_audit_metadata_is_not_a_dependency_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root)
            manifests = root / "opt/mesh-llm/manifests"
            index_path = manifests / "dependency-index.json"
            index = json.loads(index_path.read_text())
            index["files"].append({"path": "source-revision.txt",
                                   "sha256": hashlib.sha256((manifests / "source-revision.txt").read_bytes()).hexdigest()})
            write(index_path, json.dumps(index))
            with self.assertRaisesRegex(ValueError, "audit metadata"):
                collect(root, directory, expected)

    def test_indexed_stubs_and_full_audit_for_lean_are_supported(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root)
            manifests = root / "opt/mesh-llm/manifests"
            write(manifests / "crates/example/src/lib.rs", "// dependency target stub\n")
            index_path = manifests / "dependency-index.json"
            index = json.loads(index_path.read_text())
            index["files"].append({"path": "crates/example/src/lib.rs",
                                   "sha256": hashlib.sha256((manifests / "crates/example/src/lib.rs").read_bytes()).hexdigest()})
            write(index_path, json.dumps(index))
            collect(root, directory, expected)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root, "ui")
            audit_path = root / "opt/mesh-llm/manifests/manifest-index.json"
            audit = json.loads(audit_path.read_text())
            audit["manifests"].append({"path": "Cargo.toml", "sha256": "a" * 64, "ecosystem": "cargo"})
            write(audit_path, json.dumps(audit))
            collect(root, directory, expected)

    def test_provenance_and_index_formatting_do_not_change_cache_inputs(self):
        receipts = []
        for source in (SOURCE, "5" * 40):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                directory, expected = fixture(root, source=source)
                index = root / "opt/mesh-llm/manifests/dependency-index.json"
                value = json.loads(index.read_text())
                value["files"].reverse()
                write(index, json.dumps(value, indent=4))
                receipts.append(collect(root, directory, expected))
        self.assertNotEqual(receipts[0]["source"], receipts[1]["source"])
        self.assertEqual(receipts[0]["cache"], receipts[1]["cache"])
        self.assertEqual(receipts[0]["dependencies"], receipts[1]["dependencies"])

    def test_platform_abi_epoch_and_onnx_policy_change_partial_fingerprints(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root)
            receipt = collect(root, directory, expected)
            policy = json.loads((directory / "cache-policy.json").read_text())
            changed = copy.deepcopy(receipt["dependencies"])
            changed["pnpm_lifecycle"] = "onnx-skip"
            alternative = module.cache_identity(receipt["platform"], receipt["tools"], changed, policy)
            self.assertNotEqual(receipt["cache"]["input_fingerprints"]["pnpm"], alternative["input_fingerprints"]["pnpm"])
            alternative = module.cache_identity({"os": "linux", "architecture": "arm64"}, receipt["tools"], receipt["dependencies"], policy)
            self.assertNotEqual(receipt["cache"]["input_fingerprints"]["python"], alternative["input_fingerprints"]["python"])
            changed_tools = copy.deepcopy(receipt["tools"])
            changed_tools["node"]["modules_abi"] = "999"
            alternative = module.cache_identity(receipt["platform"], changed_tools, receipt["dependencies"], policy)
            self.assertNotEqual(receipt["cache"]["input_fingerprints"]["pnpm"], alternative["input_fingerprints"]["pnpm"])
            policy["epochs"]["pnpm"] += 1
            alternative = module.cache_identity(receipt["platform"], receipt["tools"], receipt["dependencies"], policy)
            self.assertNotEqual(receipt["cache"]["input_fingerprints"]["pnpm"], alternative["input_fingerprints"]["pnpm"])

    def test_python_lock_and_actual_inventory_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root)
            write(root / "etc/mesh-runner-python-requirements.lock", "example-package==1.2.4\n")
            with self.assertRaisesRegex(ValueError, "Python.*lock"):
                collect(root, directory, expected)
            write(root / "etc/mesh-runner-python-requirements.lock", "example-package==1.2.3\n")
            def wrong(arguments): return observe(arguments).replace('"example-package":"1.2.3"', '"example-package":"1.2.4"')
            with self.assertRaisesRegex(ValueError, "Python.*package"):
                collect(root, directory, expected, wrong)

    def test_policy_validation_and_bounded_command_errors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root)
            policy = json.loads((directory / "cache-policy.json").read_text())
            policy["epochs"]["pnpm"] = True
            write(directory / "cache-policy.json", json.dumps(policy))
            with self.assertRaisesRegex(ValueError, "epochs"): collect(root, directory, expected)
        class Failed:
            returncode, stderr, stdout = 9, "fixture error", ""
        with patch.object(module.subprocess, "run", return_value=Failed()) as run:
            with self.assertRaisesRegex(ValueError, "observation failed"):
                module.command(["fixture", "--version"])
            self.assertEqual(run.call_args.kwargs["timeout"], 20)
            self.assertNotIn("shell", run.call_args.kwargs)

    def test_trusted_playwright_pin_matches_existing_pin_file(self):
        pins = json.loads((repository / "config/tool-pins.json").read_text())
        self.assertEqual(pins["browser"]["playwright"], (repository / "config/playwright-pin.txt").read_text().strip())

    def test_installer_defaults_match_independent_verification_pins(self):
        pins, _ = module.read_policy(repository / "config")
        common = {"NODE_MAJOR": pins["common"]["node_major"], "PNPM_VERSION": pins["common"]["pnpm"],
                  "JUST_VERSION": pins["common"]["just"]}
        full = {"RUST_VERSION": pins["full"]["rust"], "SCCACHE_VERSION": pins["full"]["sccache"],
                "OPENAI_NPM_VERSION": pins["full"]["openai_npm"]}
        for filename, expected in (("Dockerfile", common | full), ("Dockerfile.ui", common)):
            text = (repository / filename).read_text()
            for name, value in expected.items():
                with self.subTest(file=filename, tool=name):
                    self.assertEqual(re.findall(r"^ARG " + name + r"=([^\n]+)$", text, re.M), [str(value)])

    def test_unlocked_python_runtime_package_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory, expected = fixture(root)

            def extra_package(arguments):
                output = observe(arguments)
                if arguments[1] == "-c" and Path(arguments[0]).name == "python":
                    value = json.loads(output)
                    value["packages"]["unexpected"] = "1.0.0"
                    return json.dumps(value)
                return output

            with self.assertRaisesRegex(ValueError, "inventory differs"):
                collect(root, directory, expected, extra_package)


unittest.main(argv=["runner-identity"], verbosity=1)
PY
