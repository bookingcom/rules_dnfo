"""Tests for image configuration, entrypoint, cmd, and base inheritance."""

import json
import os
import unittest


class TestImageConfig(unittest.TestCase):
    def _resolve_path(self, relpath):
        runfiles_dir = os.environ.get("RUNFILES_DIR")
        if runfiles_dir:
            candidate = os.path.join(runfiles_dir, "_main", relpath)
            if os.path.exists(candidate):
                return candidate
            candidate = os.path.join(runfiles_dir, "rules_dnfo", relpath)
            if os.path.exists(candidate):
                return candidate
        test_srcdir = os.environ.get("TEST_SRCDIR")
        if test_srcdir:
            candidate = os.path.join(test_srcdir, "_main", relpath)
            if os.path.exists(candidate):
                return candidate
            candidate = os.path.join(test_srcdir, "rules_dnfo", relpath)
            if os.path.exists(candidate):
                return candidate
        if os.path.exists(relpath):
            return relpath
        raise FileNotFoundError(f"Could not find runfile: {relpath}")

    def test_default_entrypoint_and_cmd(self):
        config_path = self._resolve_path("tests/test_defaults_image_config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        cfg = data.get("config", {})
        # Entrypoint should be omitted / null
        self.assertNotIn("Entrypoint", cfg)
        # Cmd should default to ["/bin/bash"]
        self.assertEqual(cfg.get("Cmd"), ["/bin/bash"])
        # WorkingDir should default to "/home"
        self.assertEqual(cfg.get("WorkingDir"), "/home")

    def test_base_image_inheritance(self):
        config_path = self._resolve_path("tests/test_inherit_custom_config.json")
        with open(config_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        cfg = data.get("config", {})
        # Should inherit from test_custom_base
        self.assertEqual(cfg.get("Entrypoint"), ["/usr/bin/my-app"])
        self.assertEqual(cfg.get("Cmd"), ["--flag"])
        self.assertEqual(cfg.get("WorkingDir"), "/app")
        self.assertEqual(cfg.get("User"), "1001")


if __name__ == "__main__":
    unittest.main()
