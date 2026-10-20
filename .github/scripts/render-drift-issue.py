#!/usr/bin/env python3
"""Turn the anchor checker's JSON into a GitHub issue body.

Reads `anchors.json` (written by check-chromium-anchors.sh --json) and writes
`issue_body.md`, plus `count=<n>` on stdout for $GITHUB_OUTPUT.
"""

import json
import pathlib
import sys


def main() -> int:
    data = json.loads(pathlib.Path("anchors.json").read_text())
    count = data["failure_count"]
    print(f"count={count}")
    if not count:
        return 0

    failures = "\n".join(f"- {item}" for item in data["failures"])
    body = (
        f"Chromium `{data['tag']}` (major {data['chromium_major']}, "
        f"build {data['chromium_build']}) no longer contains {count} "
        "anchor(s) that chrome++ depends on.\n\n"
        f"{failures}\n\n"
        "These are silent breakages: the build still succeeds, the feature "
        "just stops working on the affected Chrome version.\n\n"
        "Fix by updating the class names in `src/uia.cc` and the patch "
        "anchors in `src/pakpatch.cc`, then close this issue.\n\n"
        "_Automated by `.github/workflows/chromium-compatibility.yml` "
        "(`.github/scripts/render-drift-issue.py`)._\n"
    )
    pathlib.Path("issue_body.md").write_text(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
