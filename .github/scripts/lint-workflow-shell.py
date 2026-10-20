#!/usr/bin/env python3
"""Extract every workflow `run:` script and bash -n it.

GitHub only surfaces shell syntax errors once a job starts, so this catches
them locally: it walks .github/workflows/*.yml, writes each `run:` block to a
temp file and runs `bash -n`. Step names are reported for anything that fails.
"""

import pathlib
import subprocess
import sys
import tempfile

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[2]


def scripts(workflow: pathlib.Path):
    data = yaml.safe_load(workflow.read_text())
    for job_id, job in (data.get("jobs") or {}).items():
        for index, step in enumerate(job.get("steps") or [], start=1):
            body = step.get("run")
            if not body:
                continue
            name = step.get("name") or step.get("uses") or f"step {index}"
            yield f"{job_id}/{name}", body


def main() -> int:
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        for workflow in sorted((ROOT / ".github/workflows").glob("*.yml")):
            for label, body in scripts(workflow):
                checked += 1
                script = pathlib.Path(tmp) / "step.sh"
                script.write_text(body)
                result = subprocess.run(
                    ["bash", "-n", str(script)],
                    capture_output=True,
                    text=True,
                )
                if result.returncode != 0:
                    failures += 1
                    print(f"FAIL {workflow.name}:{label}", file=sys.stderr)
                    print(result.stderr.rstrip(), file=sys.stderr)
                else:
                    print(f"ok   {workflow.name}:{label}")
    print(f"\nchecked {checked} run block(s), {failures} with syntax errors")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
