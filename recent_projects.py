#!/usr/bin/env python3
"""Read recent projects and manage pinned projects using stdlib only."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
from urllib.parse import unquote, urlparse

EDITORS = (
    ("code", "Code"),
    ("code-insiders", "Code - Insiders"),
    ("codium", "VSCodium"),
    ("code-oss", "Code - OSS"),
)


def preferred_editor(rows: list[dict]) -> str:
    available = [command for command, _ in EDITORS if shutil.which(command)]
    for row in rows:
        editor = str(row.get("editor", ""))
        if editor in available:
            return editor
    return available[0] if available else "code"


def config_path() -> Path:
    root = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return root / "omarchy" / "vscode-projects.json"


def load_pins() -> list[dict]:
    try:
        value = json.loads(config_path().read_text())
    except (OSError, ValueError):
        return []
    rows = value.get("pinned", []) if isinstance(value, dict) else []
    return [row for row in rows if isinstance(row, dict) and local_path(row.get("path"))]


def save_pins(rows: list[dict]) -> None:
    target = config_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"pinned": rows}, ensure_ascii=False, indent=2) + "\n"
    with tempfile.NamedTemporaryFile("w", dir=target.parent, delete=False) as handle:
        handle.write(payload)
        temporary = handle.name
    os.replace(temporary, target)


def set_pin(path: str, editor: str, kind: str, pinned: bool) -> None:
    normalized = local_path(path)
    if not normalized:
        raise ValueError("invalid project path")
    rows = [row for row in load_pins() if local_path(row.get("path")) != normalized]
    if pinned:
        name = Path(normalized).stem if normalized.endswith(".code-workspace") else Path(normalized).name
        rows.insert(0, {"name": name or normalized, "path": normalized, "editor": editor, "kind": kind})
    save_pins(rows)


def local_path(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    if value.startswith("file://"):
        parsed = urlparse(value)
        if parsed.netloc not in ("", "localhost"):
            return None
        value = unquote(parsed.path)
    elif "://" in value:
        return None
    return os.path.abspath(os.path.expanduser(value))


def add(rows: list[dict], seen: set[str], value: object, editor: str, kind: str = "folder") -> None:
    path = local_path(value)
    if not path or path in seen or not os.path.exists(path):
        return
    seen.add(path)
    name = Path(path).stem if path.endswith(".code-workspace") else Path(path).name
    rows.append({"name": name or path, "path": path, "editor": editor, "kind": kind})


def walk_recent(value: object):
    if isinstance(value, dict):
        for key in ("folderUri", "workspace", "configPath"):
            if key in value:
                candidate = value[key]
                if isinstance(candidate, dict):
                    candidate = candidate.get("configPath") or candidate.get("path")
                if candidate:
                    yield candidate, "workspace" if key in ("workspace", "configPath") else "folder"
        for child in value.values():
            yield from walk_recent(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_recent(child)


def history_from_db(user_dir: Path) -> object | None:
    database = user_dir / "globalStorage" / "state.vscdb"
    if not database.is_file():
        return None
    try:
        uri = f"file:{database}?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=0.2) as db:
            row = db.execute(
                "SELECT value FROM ItemTable WHERE key = ?",
                ("history.recentlyOpenedPathsList",),
            ).fetchone()
        return json.loads(row[0]) if row else None
    except (OSError, sqlite3.Error, ValueError, TypeError):
        return None


def collect(limit: int, excluded: set[str] | None = None) -> list[dict]:
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    rows: list[dict] = []
    seen: set[str] = set(excluded or ())
    for executable, dirname in EDITORS:
        user_dir = config / dirname / "User"
        data = history_from_db(user_dir)
        if data is None:
            storage = user_dir / "globalStorage" / "storage.json"
            try:
                data = json.loads(storage.read_text())
            except (OSError, ValueError):
                data = None
        for value, kind in walk_recent(data):
            add(rows, seen, value, executable, kind)
        workspace_storage = user_dir / "workspaceStorage"
        try:
            metadata = sorted(workspace_storage.glob("*/workspace.json"), key=lambda p: p.stat().st_mtime, reverse=True)
        except OSError:
            metadata = []
        for item in metadata:
            try:
                doc = json.loads(item.read_text())
            except (OSError, ValueError):
                continue
            add(rows, seen, doc.get("folder") or doc.get("workspace"), executable)
    return rows[:limit]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", choices=("list", "pin", "unpin"), default="list")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--path")
    parser.add_argument("--editor", default="code")
    parser.add_argument("--kind", default="folder")
    args = parser.parse_args()
    if args.action in ("pin", "unpin"):
        if not args.path:
            parser.error("--path is required")
        set_pin(args.path, args.editor, args.kind, args.action == "pin")
        return 0
    pins = [row for row in load_pins() if os.path.exists(str(row.get("path", "")))]
    pinned_paths = {str(row["path"]) for row in pins}
    recent = collect(max(1, min(args.limit, 100)), pinned_paths)
    payload = {"pinned": pins, "recent": recent, "defaultEditor": preferred_editor(pins + recent)}
    json.dump(payload, sys.stdout, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
