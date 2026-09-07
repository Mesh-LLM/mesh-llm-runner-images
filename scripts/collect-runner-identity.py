#!/usr/bin/env python3
"""Collect runtime identity against trusted expectations without changing the image.

Cache input fingerprints are partial inputs, not cross-image reuse approval.
Consumers must retain native image/toolchain epochs, targets, features and flags.
Immutable image digests belong in a trusted external envelope, never this report.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath

VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")
SHA = re.compile(r"[0-9a-f]{40}")
UI_PATH = re.compile(r"(?:crates/mesh-llm-ui/)?(?:package\.json|package-lock\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml|yarn\.lock|\.npmrc)")
# These files describe the payload or its source. They are copied separately
# after warming and must never become dependency inputs themselves.
DEPENDENCY_METADATA = {"dependency-index.json", "manifest-index.json", "source-revision.txt", "profile.txt"}
PYTHON_PROBE = """import importlib.metadata,json,sys,sysconfig
print(json.dumps({'version':'.'.join(map(str,sys.version_info[:3])),
'abi':sysconfig.get_config_var('SOABI'),
'packages':{d.metadata['Name']:d.version for d in importlib.metadata.distributions()}}))"""
NODE_PROBE = "JSON.stringify({version:process.versions.node,modules_abi:process.versions.modules,platform:process.platform,architecture:process.arch})"
PLAYWRIGHT_PROBE = """const fs=require('fs'),path=require('path');
const p=require('playwright/package.json');
const core=require.resolve('playwright-core/package.json',{paths:[path.dirname(require.resolve('playwright/package.json'))]});
const browsers=JSON.parse(fs.readFileSync(path.join(path.dirname(core),'browsers.json'),'utf8'));
console.log(JSON.stringify({version:p.version,chromium_build:browsers.browsers.find(b=>b.name==='chromium').revision}));"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exact_keys(value, keys, name):
    require(isinstance(value, dict) and set(value) == set(keys), f"invalid {name} keys")


def digest_bytes(value):
    return "sha256:" + hashlib.sha256(value).hexdigest()


def digest_json(value):
    return digest_bytes(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def command(arguments):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=20, check=False)
    require(result.returncode == 0, f"{Path(arguments[0]).name} observation failed: {result.stderr[-1000:].strip()}")
    require(len(result.stdout.encode()) <= 1024 * 1024, "tool observation exceeds 1 MiB")
    return result.stdout.strip()


def regular_file(root, relative):
    require(isinstance(relative, str), "dependency path must be a string")
    path = PurePosixPath(relative)
    require(relative and str(path) == relative and not path.is_absolute() and ".." not in path.parts,
            f"unsafe dependency path: {relative}")
    current = root
    for part in path.parts:
        current /= part
        require(not current.is_symlink(), f"symlink in dependency path: {relative}")
    require(current.is_file(), f"missing dependency file: {relative}")
    return current


def canonical_index(root):
    require(root.is_dir() and not root.is_symlink(), "dependency root must be a real directory")
    index = json.loads(regular_file(root, "dependency-index.json").read_text())
    exact_keys(index, ("schema", "files"), "dependency index")
    require(type(index["schema"]) is int and index["schema"] == 1 and isinstance(index["files"], list), "invalid dependency index schema")
    seen, entries = set(), []
    for entry in index["files"]:
        exact_keys(entry, ("path", "sha256"), "dependency entry")
        relative, checksum = entry["path"], entry["sha256"]
        require(isinstance(relative, str) and relative not in seen, "duplicate or invalid dependency path")
        require(relative not in DEPENDENCY_METADATA, "audit metadata cannot be a dependency input")
        require(isinstance(checksum, str) and re.fullmatch(r"[0-9a-f]{64}", checksum), "invalid dependency checksum")
        require(digest_bytes(regular_file(root, relative).read_bytes()) == "sha256:" + checksum,
                f"stale dependency checksum: {relative}")
        seen.add(relative)
        entries.append({"path": relative, "sha256": checksum})
    require(entries, "empty dependency index")
    # Warming removes generated node_modules trees; Cargo fetch does not add
    # source files. Everything left here, except the explicit metadata above,
    # must therefore be covered by the canonical payload inventory.
    def walk_error(error):
        raise error

    observed = set()
    for directory, directories, files in os.walk(root, followlinks=False, onerror=walk_error):
        directory = Path(directory)
        for name in directories:
            require(not (directory / name).is_symlink(), "symlink in dependency directory")
        for name in files:
            relative = (directory / name).relative_to(root).as_posix()
            regular_file(root, relative)
            if relative not in DEPENDENCY_METADATA:
                observed.add(relative)
    require(observed == seen, "unindexed dependency payload files")
    return {"schema": 1, "files": sorted(entries, key=lambda entry: entry["path"])}


def read_policy(directory):
    pins = json.loads((directory / "tool-pins.json").read_text())
    policy = json.loads((directory / "cache-policy.json").read_text())
    exact_keys(pins, ("schema", "common", "full", "browser"), "tool pins")
    exact_keys(pins["common"], ("node_major", "pnpm", "just"), "common pins")
    exact_keys(pins["full"], ("rust", "sccache", "openai_npm"), "full pins")
    exact_keys(pins["browser"], ("playwright",), "browser pins")
    require(type(pins["schema"]) is int and pins["schema"] == 1, "invalid tool pin schema")
    require(type(pins["common"]["node_major"]) is int and pins["common"]["node_major"] > 0, "invalid Node major pin")
    for values in (pins["common"], pins["full"], pins["browser"]):
        for name, version in values.items():
            if name != "node_major":
                require(isinstance(version, str) and VERSION.fullmatch(version), f"invalid exact {name} pin")
    exact_keys(policy, ("schema", "epochs", "pnpm_lifecycle"), "cache policy")
    exact_keys(policy["epochs"], ("cargo", "sccache", "pnpm", "python"), "cache epochs")
    require(type(policy["schema"]) is int and policy["schema"] == 1, "invalid cache policy schema")
    require(all(type(value) is int and value > 0 for value in policy["epochs"].values()), "cache epochs must be positive integers")
    require(policy["pnpm_lifecycle"] == {"full": "default", "ui": "onnx-skip"}, "unsupported pnpm lifecycle policy")
    return pins, policy


def tool_version(output, name):
    match = re.match(rf"^{re.escape(name)} ({VERSION.pattern})(?:\s|$)", output.strip())
    require(match is not None, f"invalid {name} version output")
    return match.group(1)


def normalize_rust(output):
    lines = output.strip().splitlines()
    require(lines and tool_version(lines[0], "rustc"), "invalid Rust version output")
    fields = {}
    for line in lines[1:]:
        if ": " in line:
            name, value = line.split(": ", 1)
            require(name not in fields, "duplicate Rust version field")
            fields[name] = value
    require(fields.get("release") == tool_version(lines[0], "rustc"), "Rust release/header mismatch")
    require(SHA.fullmatch(fields.get("commit-hash", "")) and fields.get("host") and fields.get("LLVM version"), "incomplete Rust compiler identity")
    return {"release": fields["release"], "commit_hash": fields["commit-hash"],
            "host": fields["host"], "llvm_version": fields["LLVM version"]}


def normalized_packages(packages):
    require(isinstance(packages, dict), "invalid Python package inventory")
    result = {}
    for name, version in packages.items():
        require(isinstance(name, str) and isinstance(version, str) and version, "invalid Python package observation")
        normalized = re.sub(r"[-_.]+", "-", name).lower()
        require(normalized not in result, "duplicate normalized Python package")
        result[normalized] = version
    return result


def cache_identity(platform, tools, dependencies, policy):
    """Partial input fingerprints; native ABI and consumer recipe remain external."""
    fingerprints = {}
    inputs = {
        "pnpm": {"node": tools["node"], "pnpm": tools["pnpm"], "lifecycle": dependencies["pnpm_lifecycle"]},
        "cargo": tools["cargo"],
        "sccache": {"rustc": tools["rustc"], "sccache": tools["sccache"]} if tools["rustc"] else None,
        "python": {"python": tools["python"], "lock_sha256": dependencies["python_lock_sha256"]} if dependencies["python_lock_sha256"] else None,
    }
    for name, values in inputs.items():
        fingerprints[name] = digest_json({"schema": 1, "epoch": policy["epochs"][name], "platform": platform, "inputs": values}) if values else None
    return {"schema": 1, "epochs": policy["epochs"], "input_fingerprints": fingerprints,
            "scope": "Partial runtime inputs only. Consumers must include native image/toolchain epoch, target, features and flags; no cross-image reuse is authorized."}


def collect_identity(expected_directory, expected, verifier_revision, *, root=Path("/"), observe=command, environ=None, which=shutil.which):
    environ = os.environ if environ is None else environ
    pins, policy = read_policy(expected_directory)
    exact_keys(expected, ("environment", "backend", "mesh_revision", "cuda_series", "rocm_version", "runner_images_revision", "playwright_version"), "verification expectations")
    require(all(isinstance(expected[name], str) and SHA.fullmatch(expected[name]) for name in ("mesh_revision", "runner_images_revision"))
            and SHA.fullmatch(verifier_revision), "source/verifier revisions must be full lowercase Git SHAs")
    backend = expected["backend"]
    lean, browser = backend in {"ui", "browser"}, backend in {"web", "browser"}
    require(backend in {"cpu", "vulkan", "cuda", "rocm", "web", "ui", "browser"}, "unsupported backend")
    require(expected["environment"] in {"public", "self-hosted"} and (not (lean or browser) or expected["environment"] == "public"), "unsupported family environment")
    require((backend == "cuda" and re.fullmatch(r"[0-9]+-[0-9]+", expected["cuda_series"])) or expected["cuda_series"] == "none" and backend != "cuda", "invalid CUDA expectation")
    require((backend == "rocm" and re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", expected["rocm_version"])) or expected["rocm_version"] == "none" and backend != "rocm", "invalid ROCm expectation")
    expected_playwright = pins["browser"]["playwright"] if browser else "none"
    require(expected["playwright_version"] == expected_playwright, "Playwright argument disagrees with trusted pin")
    stamp = lambda name: (root / "etc" / name).read_text().strip()
    for name, filename in (("environment", "mesh-runner-environment"), ("backend", "mesh-runner-backend"),
            ("mesh_revision", "mesh-llm-revision"), ("runner_images_revision", "mesh-runner-images-revision"),
            ("cuda_series", "mesh-runner-cuda-series"), ("rocm_version", "mesh-runner-rocm-version")):
        require(stamp(filename) == expected[name], f"candidate {name} stamp disagrees with expectation")
    os_name, architecture = observe(["uname", "-sm"]).strip().split()
    architecture = {"x86_64": "amd64", "aarch64": "arm64"}.get(architecture)
    require(os_name == "Linux" and architecture and (not lean or architecture == "amd64"), "unsupported runtime platform")
    platform = {"os": "linux", "architecture": architecture}
    require(environ.get("ONNXRUNTIME_NODE_INSTALL") == "skip" if lean else environ.get("ONNXRUNTIME_NODE_INSTALL") in (None, ""), "ONNX lifecycle environment disagrees with image profile")
    if lean:
        require(not (root / "opt/mesh-llm/venv").exists(), "lean image contains Python AI venv")
        require(not any(which(name) for name in ("rustc", "cargo", "sccache")), "lean image contains compiler tools")
        require(not any(environ.get(name) for name in ("CARGO_HOME", "RUSTUP_HOME", "VIRTUAL_ENV")), "lean image contains compiler/venv environment")
    node_binary = f"/home/runner/externals/node{pins['common']['node_major']}/bin/node"
    global_modules = root / f"home/runner/externals/node{pins['common']['node_major']}/lib/node_modules"
    if lean:
        require(not (global_modules / "openai/package.json").exists(), "lean image unexpectedly includes OpenAI npm")
    if not browser:
        require(not (global_modules / "playwright/package.json").exists()
                and not (root / "etc/mesh-runner-playwright-version").exists(), "non-browser image unexpectedly includes Playwright")
    node = json.loads(observe([node_binary, "-p", NODE_PROBE]))
    exact_keys(node, ("version", "modules_abi", "platform", "architecture"), "Node observation")
    require(isinstance(node["version"], str) and VERSION.fullmatch(node["version"]) and int(node["version"].split(".")[0]) == pins["common"]["node_major"], "installed Node version disagrees with pin")
    require(isinstance(node["modules_abi"], str) and node["modules_abi"].isdigit() and node["platform"] == "linux"
            and node["architecture"] == {"amd64": "x64", "arm64": "arm64"}[architecture], "Node ABI/platform observation mismatch")
    pnpm = observe(["pnpm", "--version"]).strip()
    require(pnpm == pins["common"]["pnpm"], "installed pnpm version disagrees with pin")
    store = observe(["pnpm", "store", "path", "--silent"]).strip()
    require(re.fullmatch(r"/home/runner/\.local/share/pnpm/store/v[0-9]+", store) and (root / store.lstrip("/")).is_dir(), "unexpected pnpm store layout")
    just = tool_version(observe(["just", "--version"]), "just")
    require(just == pins["common"]["just"], "installed just version disagrees with pin")
    if lean:
        require(stamp("mesh-runner-node-major") == str(pins["common"]["node_major"]) and stamp("mesh-runner-pnpm-version") == pnpm, "Node/pnpm stamps disagree with installed tools")
    tools = {"node": {"version": node["version"], "modules_abi": node["modules_abi"]},
             "pnpm": {"version": pnpm, "store_format": store.rsplit("/", 1)[1]}, "just": {"version": just},
             "rustc": None, "cargo": None, "sccache": None, "openai_npm": None, "playwright": None}
    if not lean:
        tools["rustc"] = normalize_rust(observe(["/home/runner/.cargo/bin/rustc", "-vV"]))
        require(tools["rustc"]["release"] == pins["full"]["rust"], "installed Rust version disagrees with pin")
        require(tools["rustc"]["host"].startswith({"amd64": "x86_64-", "arm64": "aarch64-"}[architecture])
                and "linux" in tools["rustc"]["host"], "Rust compiler host disagrees with runtime platform")
        tools["cargo"] = {"version": tool_version(observe(["/home/runner/.cargo/bin/cargo", "--version"]), "cargo")}
        require(tools["cargo"]["version"] == pins["full"]["rust"], "installed Cargo version disagrees with Rust pin")
        tools["sccache"] = {"version": tool_version(observe(["sccache", "--version"]), "sccache")}
        require(tools["sccache"]["version"] == pins["full"]["sccache"], "installed sccache version disagrees with pin")
        package = json.loads((global_modules / "openai/package.json").read_text())
        require(package.get("version") == pins["full"]["openai_npm"], "installed OpenAI npm version disagrees with pin")
        tools["openai_npm"] = {"version": package["version"]}
    if browser:
        tools["playwright"] = json.loads(observe([node_binary, "-e", PLAYWRIGHT_PROBE]))
        exact_keys(tools["playwright"], ("version", "chromium_build"), "Playwright observation")
        require(tools["playwright"]["version"] == expected_playwright == stamp("mesh-runner-playwright-version"), "installed Playwright/stamp disagrees with pin")
        revision = tools["playwright"]["chromium_build"]
        require(isinstance(revision, str) and revision.isdigit(), "invalid Chromium build observation")
        chromium = "chromium-" + revision
        require(stamp("mesh-runner-chromium-build") == chromium and (root / "opt/ms-playwright" / chromium).is_dir(), "Chromium package/stamp/directory mismatch")
    python_binary = "python3" if lean else "/opt/mesh-llm/venv/bin/python"
    python = json.loads(observe([python_binary, "-c", PYTHON_PROBE]))
    exact_keys(python, ("version", "abi", "packages"), "Python observation")
    require(isinstance(python["version"], str) and VERSION.fullmatch(python["version"]) and isinstance(python["abi"], str) and python["abi"], "invalid Python version/ABI")
    inventory = normalized_packages(python["packages"])
    tools["python"] = {"version": python["version"], "abi": python["abi"], "runtime": "stdlib" if lean else "venv",
                       "packages_sha256": None if lean else digest_json(inventory)}
    lock_digest = None
    if not lean:
        trusted_lock = (expected_directory / "python-requirements.lock").read_bytes()
        require(trusted_lock == (root / "etc/mesh-runner-python-requirements.lock").read_bytes(), "candidate Python lock disagrees with trusted lock")
        locked = {}
        for line in trusted_lock.decode().splitlines():
            if not line.strip() or line.startswith("#"): continue
            match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9_.-]*)==([A-Za-z0-9][A-Za-z0-9._+!-]*)", line)
            require(match is not None, "Python lock must contain exact package pins")
            name = re.sub(r"[-_.]+", "-", match[1]).lower()
            require(name not in locked and inventory.get(name) == match[2], f"installed Python package disagrees with lock: {name}")
            locked[name] = match[2]
        require(locked, "empty Python runtime lock")
        require({name: version for name, version in inventory.items() if name != "pip"} == locked,
                "installed Python inventory differs from frozen runtime lock")
        observe([python_binary, "-m", "pip", "check"])
        lock_digest = digest_bytes(trusted_lock)
    manifests = root / "opt/mesh-llm/manifests"
    index = canonical_index(manifests)
    if lean:
        require(all(UI_PATH.fullmatch(entry["path"]) for entry in index["files"]), "lean dependency index includes non-UI inputs")
    require({"crates/mesh-llm-ui/package.json", "crates/mesh-llm-ui/pnpm-lock.yaml"}.issubset({entry["path"] for entry in index["files"]}), "missing UI manifest/lockfile inputs")
    audit = json.loads((manifests / "manifest-index.json").read_text())
    require(audit.get("source_revision") == expected["mesh_revision"] == (manifests / "source-revision.txt").read_text().strip(), "manifest/source provenance mismatch")
    require(audit.get("profile") == expected["environment"] == (manifests / "profile.txt").read_text().strip(), "manifest profile mismatch")
    indexed = {entry["path"]: entry["sha256"] for entry in index["files"]}
    require(isinstance(audit.get("manifests"), list) and audit["manifests"], "missing source audit inventory")
    audited = {}
    for entry in audit["manifests"]:
        exact_keys(entry, ("path", "sha256", "ecosystem"), "source audit entry")
        require(isinstance(entry["path"], str) and entry["path"] not in audited, "duplicate or invalid source audit path")
        require(isinstance(entry["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]), "invalid source audit checksum")
        audited[entry["path"]] = entry["sha256"]
    require(all(audited.get(path) == checksum for path, checksum in indexed.items() if lean or path in audited), "audit/dependency checksum mismatch")
    require(all(indexed.get(path) == checksum for path, checksum in audited.items() if not lean or UI_PATH.fullmatch(path)),
            "source audit input missing from dependency index")
    kind = "ui" if lean else "full"
    dependencies = {"kind": kind, "index_sha256": digest_json(index), "python_lock_sha256": lock_digest,
                    "pnpm_lifecycle": policy["pnpm_lifecycle"][kind]}
    expected_tools = {**pins["common"], **{name: None if lean else value for name, value in pins["full"].items()},
                      "playwright": pins["browser"]["playwright"] if browser else None}
    return {"schema": 1, "type": "mesh-llm-runner-runtime-identity", "platform": platform,
            "family": {"environment": expected["environment"], "backend": backend,
                       "cuda_series": None if expected["cuda_series"] == "none" else expected["cuda_series"],
                       "rocm_version": None if expected["rocm_version"] == "none" else expected["rocm_version"]},
            "source": {"mesh_revision": expected["mesh_revision"], "runner_images_revision": expected["runner_images_revision"]},
            "verification": {"verifier_revision": verifier_revision, "tool_pins_sha256": digest_json(pins), "cache_policy_sha256": digest_json(policy)},
            "expected_tools": expected_tools, "tools": tools, "dependencies": dependencies,
            "cache": cache_identity(platform, tools, dependencies, policy)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-directory", type=Path, required=True)
    parser.add_argument("--verifier-revision", required=True)
    for name in ("environment", "backend", "mesh_revision", "cuda_series", "rocm_version", "runner_images_revision", "playwright_version"):
        parser.add_argument(name)
    args = vars(parser.parse_args())
    directory, verifier = args.pop("expected_directory"), args.pop("verifier_revision")
    print(json.dumps(collect_identity(directory, args, verifier), indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"runner identity collection failed: {error}") from error
