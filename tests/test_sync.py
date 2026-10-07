"""Filesystem and Git fixtures only; never touch the real home or network."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="agents-sync-")
        self.addCleanup(self.scratch.cleanup)
        base = Path(self.scratch.name)
        self.root = base / "agents"
        self.home = base / "home"
        self.root.mkdir()
        self.home.mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1] / "sync.py", self.root / "sync.py")
        self.env = dict(os.environ, HOME=str(self.home), GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1")
        self.manifest = {"version": 1, "agents": {
            "codex": {"destination": "~/.agents/skills", "skills": ["skills/review"]},
            "claude-code": {"destination": "~/.claude/skills", "skills": ["skills/review"]},
            "pi": {"destination": None, "skills": []},
        }}
        self.sources = {"version": 1, "repositories": [], "imports": []}
        self.skill("skills/review")

    def skill(self, path):
        directory = self.root / path
        directory.mkdir(parents=True)
        (directory / "SKILL.md").write_text("---\nname: review\ndescription: Mock review skill\n---\n")
        return directory

    def run_sync(self, *args):
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        (self.root / "sources.json").write_text(json.dumps(self.sources))
        return subprocess.run([sys.executable, str(self.root / "sync.py"), *args],
                              env=self.env, text=True, capture_output=True)

    def test_plan_has_no_home_mutations_and_apply_is_repeatable(self):
        self.assertEqual(self.run_sync().returncode, 0)
        self.assertEqual(list(self.home.iterdir()), [])
        self.assertEqual(self.run_sync("--apply").returncode, 0)
        for directory in [".agents", ".claude"]:
            link = self.home / directory / "skills/review"
            self.assertTrue(link.is_symlink())
            self.assertEqual(link.resolve(), self.root / "skills/review")
        result = self.run_sync("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.count("keep:"), 2)

    def test_all_targets_preflight_before_any_creation(self):
        existing = self.home / ".claude/skills/review"
        existing.mkdir(parents=True)
        result = self.run_sync("--apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.home / ".agents").exists())
        self.assertTrue(existing.is_dir())

    def test_conflicting_broken_link_is_preserved(self):
        directory = self.home / ".agents/skills"
        directory.mkdir(parents=True)
        link = directory / "review"
        link.symlink_to(self.home / "missing")
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        self.assertEqual(os.readlink(link), str(self.home / "missing"))

    def test_existing_file_and_reserved_skill_are_refused(self):
        directory = self.home / ".agents/skills"
        directory.mkdir(parents=True)
        existing = directory / "review"
        existing.write_text("preserve")
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        self.assertEqual(existing.read_text(), "preserve")
        self.skill("skills/synced")
        self.manifest["agents"]["claude-code"]["skills"] = ["skills/synced"]
        self.assertNotEqual(self.run_sync("--apply", "--agent", "claude-code").returncode, 0)
        self.assertFalse((self.home / ".claude").exists())

    def test_source_symlink_cannot_escape_repository(self):
        outside = Path(self.scratch.name) / "outside"
        outside.mkdir()
        (outside / "SKILL.md").write_text("mock")
        (self.root / "skills/escape").symlink_to(outside)
        self.manifest["agents"]["codex"]["skills"] = ["skills/escape"]
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_symlinked_discovery_parent_is_refused(self):
        elsewhere = Path(self.scratch.name) / "elsewhere"
        elsewhere.mkdir()
        (self.home / ".agents").symlink_to(elsewhere)
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_unselected_existing_skills_are_retained(self):
        directory = self.home / ".agents/skills"
        directory.mkdir(parents=True)
        unrelated = directory / "other"
        unrelated.write_text("preserve")
        self.assertEqual(self.run_sync("--apply", "--agent", "codex").returncode, 0)
        self.assertEqual(unrelated.read_text(), "preserve")
        self.assertFalse((self.home / ".claude").exists())
        self.manifest["agents"]["codex"]["skills"] = []
        self.assertEqual(self.run_sync("--apply", "--agent", "codex").returncode, 0)
        self.assertTrue((directory / "review").is_symlink())

    def test_invalid_selections_refuse_without_mutations(self):
        original = json.dumps(self.manifest)
        cases = [
            ("skills", ["../outside"]),
            ("skills", ["skills/missing"]),
            ("skills", ["skills/review", "skills/review"]),
            ("destination", "~/../outside"),
            ("destination", "/tmp/unsafe"),
        ]
        for field, value in cases:
            with self.subTest(field=field, value=value):
                self.manifest = json.loads(original)
                self.manifest["agents"]["codex"][field] = value
                self.assertNotEqual(self.run_sync("--apply").returncode, 0)
                self.assertEqual(list(self.home.iterdir()), [])
        self.manifest = json.loads(original)
        self.manifest["agents"]["pi"]["skills"] = ["skills/review"]
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        self.assertNotEqual(self.run_sync("--agent", "unknown").returncode, 0)

    def test_locked_vendor_revision_origin_and_cleanliness(self):
        vendor = self.skill("vendor/example/skills/review")
        repository = vendor.parents[1]

        def git(*args):
            result = subprocess.run(["git", "-C", str(repository), *args],
                                    env=self.env, capture_output=True, text=True, check=True)
            return result.stdout.strip()

        git("init", "-b", "main")
        git("remote", "add", "origin", "https://github.com/example/skills.git")
        git("add", ".")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Mock skill")
        record = {"path": "vendor/example", "repository": "https://github.com/example/skills.git",
                  "revision": git("rev-parse", "HEAD")}
        self.sources["repositories"] = [record]
        self.manifest["agents"]["codex"]["skills"] = ["vendor/example/skills/review"]
        self.assertEqual(self.run_sync().returncode, 0)
        revision = record["revision"]
        record["revision"] = "0" * 40
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        record["revision"] = revision
        record["repository"] = "https://github.com/other/skills.git"
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        record["repository"] = "https://github.com/example/skills.git"
        (vendor / "SKILL.md").write_text("changed")
        self.assertNotEqual(self.run_sync("--apply").returncode, 0)
        self.assertEqual(list(self.home.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
