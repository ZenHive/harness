#!/usr/bin/env python3
"""Capture a real planner invocation without changing its arguments or plan."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(os.environ["PLANNER_EVIDENCE_DIR"])
root.mkdir(parents=True, exist_ok=True)
(root / "prompt.txt").write_text(sys.argv[-1])
git = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], capture_output=True, text=True)
(root / "invocation.json").write_text(json.dumps({
    "cwd": os.getcwd(), "argv": sys.argv[1:-1],
    "git_exit": git.returncode, "git_output": git.stdout + git.stderr,
}))
with (root / "transcript.jsonl").open("w") as transcript:
    child = subprocess.Popen([os.environ["PLANNER_REAL_CODEX"], *sys.argv[1:]],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in child.stdout:
        transcript.write(line)
        transcript.flush()
        print(line, end="", flush=True)
    status = child.wait()
plan = Path(".harness/cron-plan.json")
if plan.exists():
    shutil.copyfile(plan, root / "cron-plan.json")
(root / "exit-status.txt").write_text(str(status))
sys.exit(status)
