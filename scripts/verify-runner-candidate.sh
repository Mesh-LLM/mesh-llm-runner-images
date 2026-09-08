#!/usr/bin/env bash
set -euo pipefail

# This helper belongs only in verification contexts, never production images.
# Its expected directory comes from the verification checkout, not the image.
exec python3 -B - "$@" <<'PY'
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description="Verify a runner against independent checkout inputs.")
parser.add_argument("--expected-directory", type=Path, required=True)
parser.add_argument("--verifier-revision", required=True)
for name in ("environment", "backend", "mesh_revision", "cuda_series", "rocm_version",
             "runner_images_revision", "playwright_version"):
    parser.add_argument(name)
args = parser.parse_args()
directory = args.expected_directory
expected = [getattr(args, name) for name in ("environment", "backend", "mesh_revision", "cuda_series",
            "rocm_version", "runner_images_revision", "playwright_version")]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def health_command(command):
    # Keep stdout reserved for the final successful runtime report.
    result = subprocess.run(command, stdout=sys.stderr, check=False)
    if result.returncode:
        raise SystemExit(result.returncode if result.returncode > 0 else 1)


try:
    for filename in ("verify-runner-image.sh", "collect-runner-identity.py", "tool-pins.json",
                     "cache-policy.json", "python-requirements.lock", "playwright-pin.txt"):
        require((directory / filename).is_file(), f"missing independent verification input: {filename}")
    spec = importlib.util.spec_from_file_location("runner_identity", directory / "collect-runner-identity.py")
    identity = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(identity)
    pins, policy = identity.read_policy(directory)
    require(all(re.fullmatch(r"[0-9a-f]{40}", value) for value in (
        args.mesh_revision, args.runner_images_revision, args.verifier_revision)),
        "source and verifier revisions must be full lowercase Git SHAs")
    require(args.environment in {"public", "self-hosted"}, "unsupported environment")
    require(args.backend in {"cpu", "vulkan", "cuda", "rocm", "web", "ui", "browser"}, "unsupported backend")
    require(args.backend not in {"web", "ui", "browser"} or args.environment == "public", "unsupported browser/UI environment")
    require(bool(re.fullmatch(r"[0-9]+-[0-9]+", args.cuda_series)) if args.backend == "cuda"
            else args.cuda_series == "none", "invalid CUDA expectation")
    require(bool(re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", args.rocm_version)) if args.backend == "rocm"
            else args.rocm_version == "none", "invalid ROCm expectation")
    playwright_pin = (directory / "playwright-pin.txt").read_text().strip()
    require(playwright_pin == pins["browser"]["playwright"], "independent Playwright pin files disagree")
    require(args.playwright_version == (playwright_pin if args.backend in {"web", "browser"} else "none"),
            "Playwright expectation disagrees with independent pin")

    health_command(["bash", str(directory / "verify-runner-image.sh"), *expected])
    for major in (20, 24):
        for prefix in ("/home/runner/externals", "/__e"):
            binary = Path(prefix) / f"node{major}/bin/node"
            require(binary.is_file() and os.access(binary, os.X_OK), f"missing executable Actions Node path: {binary}")
            health_command([str(binary), "-e",
                f'if (process.versions.node.split(".")[0] !== "{major}") process.exit(1);'])

    result = subprocess.run([sys.executable, "-B", str(directory / "collect-runner-identity.py"),
        "--expected-directory", str(directory), "--verifier-revision", args.verifier_revision, *expected],
        capture_output=True, text=True, check=False)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode if result.returncode > 0 else 1)
    report = json.loads(result.stdout)
    identity.exact_keys(report, ("schema", "type", "platform", "family", "source", "verification",
                               "expected_tools", "tools", "dependencies", "cache"), "runtime identity")
    require(type(report["schema"]) is int and report["schema"] == 1
            and report["type"] == "mesh-llm-runner-runtime-identity", "unsupported runtime identity schema")
    require(report["source"] == {"mesh_revision": args.mesh_revision,
            "runner_images_revision": args.runner_images_revision}, "runtime report source mismatch")
    require(report["verification"] == {"verifier_revision": args.verifier_revision,
            "tool_pins_sha256": identity.digest_json(pins), "cache_policy_sha256": identity.digest_json(policy)},
            "runtime report verification mismatch")
    print(json.dumps(report, indent=2))
except (ValueError, KeyError, TypeError, OSError) as error:
    raise SystemExit(f"runner candidate verification failed: {error}") from error
PY
