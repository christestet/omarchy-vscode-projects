import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

import recent_projects


class RecentProjectsTest(unittest.TestCase):
    def test_reads_manifest_version(self):
        with tempfile.TemporaryDirectory() as temp:
            manifest = Path(temp) / "manifest.json"
            manifest.write_text(json.dumps({"version": "1.2.3"}))
            self.assertEqual(recent_projects.manifest_version(manifest), "1.2.3")

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

    def test_rejects_oversized_regular_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "large.json"
            path.write_bytes(b" " * 17)
            self.assertIsNone(recent_projects.read_json(path, max_bytes=16))

    def test_rejects_symlinked_json_file(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "target.json"
            target.write_text("{}")
            link = Path(temp) / "link.json"
            link.symlink_to(target)
            self.assertIsNone(recent_projects.read_json(link))

    def test_rejects_excessively_nested_json(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "deep.json"
            path.write_text("[" * 100_000 + "0" + "]" * 100_000)
            self.assertIsNone(recent_projects.read_json(path))

    def test_sqlite_value_is_bounded(self):
        with tempfile.TemporaryDirectory() as temp:
            user_dir = Path(temp) / "User"
            database = user_dir / "globalStorage/state.vscdb"
            database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                db.execute("INSERT INTO ItemTable VALUES (?, ?)", ("history.recentlyOpenedPathsList", "x" * 20))
            with patch.object(recent_projects, "MAX_SQL_VALUE_BYTES", 16):
                self.assertIsNone(recent_projects.history_from_db(user_dir))

    def test_sqlite_path_is_uri_encoded(self):
        with tempfile.TemporaryDirectory(prefix="vscode?#") as temp:
            user_dir = Path(temp) / "User"
            database = user_dir / "globalStorage/state.vscdb"
            database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                db.execute("INSERT INTO ItemTable VALUES (?, ?)", ("history.recentlyOpenedPathsList", "{}"))
            self.assertEqual(recent_projects.history_from_db(user_dir), {})

    def test_rejects_symlinked_sqlite_database(self):
        with tempfile.TemporaryDirectory() as temp:
            user_dir = Path(temp) / "User"
            database = user_dir / "globalStorage/state.vscdb"
            database.parent.mkdir(parents=True)
            target = Path(temp) / "actual.vscdb"
            target.touch()
            database.symlink_to(target)
            self.assertIsNone(recent_projects.history_from_db(user_dir))

    def test_walk_recent_obeys_depth_and_node_limits(self):
        value = {"first": {"folderUri": "/first"}, "second": {"folderUri": "/second"}}
        self.assertEqual(list(recent_projects.walk_recent(value, max_nodes=2)), [("/first", "folder")])
        deep = {"child": {"folderUri": "/too-deep"}}
        self.assertEqual(list(recent_projects.walk_recent(deep, max_depth=0)), [])

    def test_collect_stops_after_requested_result_count(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            projects = []
            for name in ("one", "two"):
                project = root / name
                project.mkdir()
                projects.append(project)
            storage = root / "Code/User/globalStorage/storage.json"
            storage.parent.mkdir(parents=True)
            storage.write_text(json.dumps({"entries": [{"folderUri": path.as_uri()} for path in projects]}))
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp}):
                rows = recent_projects.collect(1)
            self.assertEqual(len(rows), 1)
            self.assertEqual(recent_projects.collect(0), [])

    def test_output_is_bounded(self):
        with patch.object(recent_projects, "MAX_OUTPUT_BYTES", 8):
            self.assertFalse(recent_projects.write_payload({"recent": []}))

    def test_pins_are_counted_and_field_lengths_are_bounded(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / "omarchy/vscode-projects.json"
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps({"pinned": [{"path": "/tmp", "name": "x" * 1000}] * 3}))
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp}), patch.object(recent_projects, "MAX_PINS", 2):
                pins = recent_projects.load_pins()
            self.assertEqual(len(pins), 2)
            self.assertEqual(len(pins[0]["name"]), recent_projects.MAX_NAME_CHARS)

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

    def test_pin_fields_and_count_are_bounded_on_write(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp) / "favorite"
            project.mkdir()
            config = Path(temp) / "config"
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(config)}), patch.object(recent_projects, "MAX_PINS", 1):
                recent_projects.set_pin(str(project), "e" * 1000, "k" * 1000, True)
                pin = recent_projects.load_pins()[0]
                self.assertEqual(len(pin["editor"]), 64)
                self.assertEqual(len(pin["kind"]), 64)
                recent_projects.save_pins([pin, pin])
                saved = json.loads(recent_projects.config_path().read_text())
                self.assertEqual(len(saved["pinned"]), 1)

    def test_clear_pins(self):
        with tempfile.TemporaryDirectory() as temp:
            project = Path(temp) / "favorite"
            project.mkdir()
            config = Path(temp) / "config"
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": str(config)}):
                recent_projects.set_pin(str(project), "code", "folder", True)
                recent_projects.clear_pins()
                self.assertEqual(recent_projects.load_pins(), [])

    def test_prefers_available_editor_used_by_project(self):
        with patch("recent_projects.shutil.which", side_effect=lambda command: "/usr/bin/" + command if command in ("code", "codium") else None):
            self.assertEqual(recent_projects.preferred_editor([{"editor": "codium"}]), "codium")

    def test_falls_back_to_first_available_editor(self):
        with patch("recent_projects.shutil.which", side_effect=lambda command: "/usr/bin/codium" if command == "codium" else None):
            self.assertEqual(recent_projects.preferred_editor([]), "codium")


if __name__ == "__main__":
    unittest.main()
