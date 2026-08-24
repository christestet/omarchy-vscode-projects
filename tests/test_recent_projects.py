import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import recent_projects


class RecentProjectsTest(unittest.TestCase):
    def test_file_uri(self):
        self.assertEqual(recent_projects.local_path("file:///tmp/hello%20world"), "/tmp/hello world")
        self.assertIsNone(recent_projects.local_path("vscode-remote://ssh-remote/project"))

    def test_collects_storage_json(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            project = root / "project"
            project.mkdir()
            storage = root / "Code/User/globalStorage/storage.json"
            storage.parent.mkdir(parents=True)
            storage.write_text(json.dumps({"entries": [{"folderUri": project.as_uri()}]}))
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp}):
                rows = recent_projects.collect(5)
            self.assertEqual(rows[0]["path"], str(project))
            self.assertEqual(rows[0]["editor"], "code")

    def test_pin_round_trip(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp) / "favorite"
            project.mkdir()
            config = Path(temp) / "config"
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(config)}):
                recent_projects.set_pin(str(project), "codium", "folder", True)
                self.assertEqual(recent_projects.load_pins()[0]["path"], str(project))
                recent_projects.set_pin(str(project), "codium", "folder", False)
                self.assertEqual(recent_projects.load_pins(), [])


if __name__ == "__main__":
    unittest.main()
