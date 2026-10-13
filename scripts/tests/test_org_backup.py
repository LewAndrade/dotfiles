"""Test the backup runner with fake Git and a disposable notes directory.

Run: python3 -m unittest discover -s scripts/tests
No real repository, credentials, commit, or push is used.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / ".local/bin/org-backup"
FAKE_GIT = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
with open(os.environ["GIT_TRACE_FILE"], "a") as output:
    output.write(" ".join(args) + "\\n")
if args[:2] == ["rev-parse", "--git-path"]:
    print(".git/org-backup.lock")
elif args == ["status", "--porcelain"]:
    if os.environ.get("DIRTY"):
        print(" M notes.org")
elif args[:1] == ["pull"]:
    Path(os.environ["PULL_STARTED"]).touch()
    while os.environ.get("HOLD_PULL") and not Path(os.environ["PULL_RELEASE"]).exists():
        time.sleep(0.01)
    if os.environ.get("FAIL_PULL"):
        print("Disposable pull failure", file=sys.stderr)
        sys.exit(1)
elif args[:1] == ["commit"] and os.environ.get("FAIL_COMMIT"):
    sys.exit(1)
elif args[:1] == ["log"]:
    print("fakecommit")
"""


class OrgBackupTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="org-backup-test-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "Documents/org"
        (self.repo / ".git").mkdir(parents=True)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        git = bin_dir / "git"
        git.write_text(FAKE_GIT)
        git.chmod(0o755)
        self.trace = self.root / "git-trace"
        self.started = self.root / "pull-started"
        self.release = self.root / "pull-release"
        self.environment = dict(
            os.environ,
            HOME=str(self.root),
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            GIT_TRACE_FILE=str(self.trace),
            PULL_STARTED=str(self.started),
            PULL_RELEASE=str(self.release),
        )

    def tearDown(self):
        self.temporary.cleanup()

    def run_backup(self, **settings):
        return subprocess.run(
            ["/bin/sh", str(SCRIPT)],
            env=dict(self.environment, **settings),
            capture_output=True,
            text=True,
            timeout=10,
        )

    def assert_lock_released(self):
        self.assertFalse((self.repo / ".git/org-backup.lock").exists())

    def test_success_releases_lock(self):
        result = self.run_backup(DIRTY="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("committed fakecommit", result.stdout)
        self.assertIn("pushed", result.stdout)
        self.assert_lock_released()

    def test_pull_failure_releases_lock(self):
        result = self.run_backup(FAIL_PULL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ERROR pull --rebase failed", result.stdout)
        self.assert_lock_released()

    def test_commit_failure_releases_lock(self):
        result = self.run_backup(DIRTY="1", FAIL_COMMIT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assert_lock_released()

    def test_existing_lock_is_not_deleted(self):
        lock = self.repo / ".git/org-backup.lock"
        lock.mkdir()
        owner = lock / "pid"
        owner.write_text("123456789\n")
        result = self.run_backup()
        self.assertEqual(result.returncode, 0)
        self.assertIn("SKIP backup lock exists", result.stdout)
        self.assertEqual(owner.read_text(), "123456789\n")
        self.assertNotIn("pull", self.trace.read_text())

    def test_concurrent_run_skips_and_next_run_works(self):
        first = subprocess.Popen(
            ["/bin/sh", str(SCRIPT)],
            env=dict(self.environment, HOLD_PULL="1"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while not self.started.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(self.started.exists(), "First backup did not reach Git pull")
            second = self.run_backup()
            self.assertEqual(second.returncode, 0)
            self.assertIn("SKIP backup lock exists", second.stdout)
            self.assertEqual(self.trace.read_text().count("pull -q --rebase origin master"), 1)
        finally:
            self.release.touch()
            first.communicate(timeout=10)
        self.assertEqual(first.returncode, 0)
        self.assert_lock_released()
        self.assertEqual(self.run_backup().returncode, 0)
        self.assert_lock_released()


if __name__ == "__main__":
    unittest.main()
