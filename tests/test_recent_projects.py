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
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp, "VSCODE_SHARED_DATA_HOME": temp}):
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
            database = Path(temp) / "state.vscdb"
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                db.execute("INSERT INTO ItemTable VALUES (?, ?)", ("history.recentlyOpenedPathsList", "x" * 20))
            with patch.object(recent_projects, "MAX_SQL_VALUE_BYTES", 16):
                self.assertIsNone(recent_projects.history_from_db(database))

    def test_sqlite_path_is_uri_encoded(self):
        with tempfile.TemporaryDirectory(prefix="vscode?#") as temp:
            database = Path(temp) / "state.vscdb"
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                db.execute("INSERT INTO ItemTable VALUES (?, ?)", ("history.recentlyOpenedPathsList", "{}"))
            self.assertEqual(recent_projects.history_from_db(database), {})

    def test_reads_wal_backed_database_through_descriptor_snapshot(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp) / "state.vscdb"
            writer = sqlite3.connect(database)
            try:
                writer.execute("PRAGMA journal_mode = WAL")
                writer.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                writer.execute("INSERT INTO ItemTable VALUES (?, ?)", (
                    "history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": "file:///tmp/project"}]}),
                ))
                writer.commit()
                self.assertEqual(recent_projects.history_from_db(database), {
                    "entries": [{"folderUri": "file:///tmp/project"}],
                })
            finally:
                writer.close()

    def test_rejects_oversized_sqlite_sidecar(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp) / "state.vscdb"
            database.touch()
            Path(str(database) + "-wal").write_bytes(b"x" * 17)
            with patch.object(recent_projects, "MAX_DATABASE_BYTES", 16):
                self.assertIsNone(recent_projects.open_database_descriptors(database))

    def test_rejects_symlinked_sqlite_database(self):
        with tempfile.TemporaryDirectory() as temp:
            database = Path(temp) / "state.vscdb"
            target = Path(temp) / "actual.vscdb"
            target.touch()
            database.symlink_to(target)
            self.assertIsNone(recent_projects.history_from_db(database))

    def test_recent_entries_are_ordered_and_schema_bound(self):
        value = {
            "entries": [
                {"folderUri": "/first"},
                {"workspace": {"configPath": "/second.code-workspace"}},
                {"nested": {"folderUri": "/ignored"}},
            ]
        }
        self.assertEqual(list(recent_projects.recent_entries(value)), [
            ("/first", "folder"),
            ("/second.code-workspace", "workspace"),
        ])

    def test_recent_entries_are_bounded(self):
        value = {"entries": [{"folderUri": f"/{index}"} for index in range(3)]}
        with patch.object(recent_projects, "MAX_RECENT_ENTRIES", 2):
            self.assertEqual(list(recent_projects.recent_entries(value)), [("/0", "folder"), ("/1", "folder")])

    def test_collect_prefers_current_shared_history(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            current = root / "current"
            legacy = root / "legacy"
            current.mkdir()
            legacy.mkdir()
            database = root / ".vscode-shared/sharedStorage/state.vscdb"
            database.parent.mkdir(parents=True)
            with sqlite3.connect(database) as db:
                db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                db.execute("INSERT INTO ItemTable VALUES (?, ?)", (
                    "history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": current.as_uri()}]}),
                ))
            legacy_database = root / "Code/User/globalStorage/state.vscdb"
            legacy_database.parent.mkdir(parents=True)
            with sqlite3.connect(legacy_database) as db:
                db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
                db.execute("INSERT INTO ItemTable VALUES (?, ?)", (
                    "history.recentlyOpenedPathsList", json.dumps({"entries": [{"folderUri": legacy.as_uri()}]}),
                ))
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp, "VSCODE_SHARED_DATA_HOME": temp}):
                rows = recent_projects.collect(5)
            self.assertEqual([row["path"] for row in rows], [str(current)])

    def test_does_not_scan_workspace_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            project = root / "project"
            project.mkdir()
            workspace = root / "Code/User/workspaceStorage/stale/workspace.json"
            workspace.parent.mkdir(parents=True)
            workspace.write_text(json.dumps({"folder": project.as_uri()}))
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp, "VSCODE_SHARED_DATA_HOME": temp}):
                self.assertEqual(recent_projects.collect(5), [])

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
            with patch.dict(os.environ, {"XDG_CONFIG_HOME": temp, "VSCODE_SHARED_DATA_HOME": temp}):
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
