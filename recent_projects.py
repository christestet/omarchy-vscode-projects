#!/usr/bin/env python3
"""Read recent projects and manage pinned projects using stdlib only."""

from __future__ import annotations

import argparse
from itertools import islice
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import sys
import tempfile
from urllib.parse import unquote, urlparse

EDITORS = (
    ("code", "Code"),
    ("code-insiders", "Code - Insiders"),
    ("codium", "VSCodium"),
    ("code-oss", "Code - OSS"),
)

# VS Code's state is replaceable, externally controlled input.  Keep every
# stage bounded so corrupt or unexpectedly large state cannot stall the shell.
MAX_JSON_BYTES = 1024 * 1024
MAX_DATABASE_BYTES = 64 * 1024 * 1024
MAX_SQL_VALUE_BYTES = MAX_JSON_BYTES
MAX_SQL_STEPS = 100_000
MAX_WORKSPACE_FILES = 256
MAX_WALK_NODES = 4096
MAX_WALK_DEPTH = 20
MAX_PATH_CHARS = 2048
MAX_NAME_CHARS = 256
MAX_PINS = 100
MAX_OUTPUT_BYTES = 512 * 1024


def read_regular_file(path: Path, max_bytes: int = MAX_JSON_BYTES) -> str | None:
    """Read a small regular file without following a size-changing stream."""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > max_bytes:
            return None
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = None
            data = handle.read(max_bytes + 1)
    except OSError:
        return None
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if len(data) > max_bytes:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def read_json(path: Path, max_bytes: int = MAX_JSON_BYTES) -> object | None:
    text = read_regular_file(path, max_bytes)
    if text is None:
        return None
    try:
        return json.loads(text)
    except (ValueError, TypeError, RecursionError):
        return None


def regular_file_within(path: Path, max_bytes: int) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and info.st_size <= max_bytes


def manifest_version(path: Path | None = None) -> str:
    target = path or Path(__file__).with_name("manifest.json")
    value = read_json(target)
    if not isinstance(value, dict):
        return ""
    version = value.get("version", "")
    return str(version)[:64] if isinstance(version, (str, int, float)) else ""


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
    value = read_json(config_path())
    rows = value.get("pinned", []) if isinstance(value, dict) else []
    pins = []
    for row in rows[:MAX_PINS]:
        if not isinstance(row, dict):
            continue
        path = local_path(row.get("path"))
        if not path:
            continue
        fallback = Path(path).stem if path.endswith(".code-workspace") else Path(path).name
        pins.append({
            "name": str(row.get("name") or fallback or path)[:MAX_NAME_CHARS],
            "path": path,
            "editor": str(row.get("editor") or "code")[:64],
            "kind": str(row.get("kind") or "folder")[:64],
        })
    return pins


def save_pins(rows: list[dict]) -> None:
    target = config_path()
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"pinned": rows[:MAX_PINS]}, ensure_ascii=False, indent=2) + "\n"
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
        rows.insert(0, {
            "name": (name or normalized)[:MAX_NAME_CHARS],
            "path": normalized,
            "editor": str(editor)[:64],
            "kind": str(kind)[:64],
        })
    save_pins(rows)


def clear_pins() -> None:
    save_pins([])


def local_path(value: object) -> str | None:
    if not isinstance(value, str) or not value or len(value) > MAX_PATH_CHARS:
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


def walk_recent(value: object, max_nodes: int = MAX_WALK_NODES, max_depth: int = MAX_WALK_DEPTH):
    """Iteratively inspect a bounded portion of nested recent-project data."""
    stack = [(value, 0)]
    visited = 0
    while stack and visited < max_nodes:
        current, depth = stack.pop()
        visited += 1
        if isinstance(current, dict):
            for key in ("folderUri", "workspace", "configPath"):
                if key in current:
                    candidate = current[key]
                    if isinstance(candidate, dict):
                        candidate = candidate.get("configPath") or candidate.get("path")
                    if candidate:
                        yield candidate, "workspace" if key in ("workspace", "configPath") else "folder"
            if depth < max_depth:
                remaining = max_nodes - visited
                children = list(islice(current.values(), remaining))
                stack.extend((child, depth + 1) for child in reversed(children))
        elif isinstance(current, list) and depth < max_depth:
            remaining = max_nodes - visited
            stack.extend((child, depth + 1) for child in reversed(current[:remaining]))


def history_from_db(user_dir: Path) -> object | None:
    database = user_dir / "globalStorage" / "state.vscdb"
    if not regular_file_within(database, MAX_DATABASE_BYTES):
        return None
    for suffix in ("-wal", "-shm", "-journal"):
        auxiliary = Path(str(database) + suffix)
        try:
            exists = auxiliary.exists() or auxiliary.is_symlink()
        except OSError:
            return None
        if exists and not regular_file_within(auxiliary, MAX_DATABASE_BYTES):
            return None
    try:
        uri = database.absolute().as_uri() + "?mode=ro"
        with sqlite3.connect(uri, uri=True, timeout=0.2) as db:
            db.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_SQL_VALUE_BYTES)
            db.set_progress_handler(lambda: 1, MAX_SQL_STEPS)
            row = db.execute(
                "SELECT value FROM ItemTable WHERE key = ? AND length(CAST(value AS BLOB)) <= ? LIMIT 1",
                ("history.recentlyOpenedPathsList", MAX_SQL_VALUE_BYTES),
            ).fetchone()
        return json.loads(row[0]) if row else None
    except (OSError, sqlite3.Error, ValueError, TypeError, RecursionError):
        return None


def collect(limit: int, excluded: set[str] | None = None) -> list[dict]:
    limit = max(0, min(int(limit), 100))
    if limit == 0:
        return []
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    rows: list[dict] = []
    seen: set[str] = set(excluded or ())
    for executable, dirname in EDITORS:
        if len(rows) >= limit:
            break
        user_dir = config / dirname / "User"
        data = history_from_db(user_dir)
        if data is None:
            storage = user_dir / "globalStorage" / "storage.json"
            data = read_json(storage)
        for value, kind in walk_recent(data):
            add(rows, seen, value, executable, kind)
            if len(rows) >= limit:
                break
        if len(rows) >= limit:
            continue
        workspace_storage = user_dir / "workspaceStorage"
        try:
            metadata = []
            with os.scandir(workspace_storage) as entries:
                for inspected, entry in enumerate(entries):
                    if inspected >= MAX_WORKSPACE_FILES:
                        break
                    try:
                        item = Path(entry.path) / "workspace.json"
                        if entry.is_dir(follow_symlinks=False) and item.is_file():
                            metadata.append((item.stat().st_mtime, item))
                    except OSError:
                        continue
            metadata.sort(key=lambda pair: pair[0], reverse=True)
        except OSError:
            metadata = []
        for _, item in metadata:
            doc = read_json(item)
            if not isinstance(doc, dict):
                continue
            add(rows, seen, doc.get("folder") or doc.get("workspace"), executable)
            if len(rows) >= limit:
                break
    return rows[:limit]


def write_payload(payload: dict) -> bool:
    encoded = (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(encoded) > MAX_OUTPUT_BYTES:
        return False
    sys.stdout.buffer.write(encoded)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", choices=("list", "pin", "unpin", "unpin-all"), default="list")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--path")
    parser.add_argument("--editor", default="code")
    parser.add_argument("--kind", default="folder")
    args = parser.parse_args()
    if args.action == "unpin-all":
        clear_pins()
        return 0
    if args.action in ("pin", "unpin"):
        if not args.path:
            parser.error("--path is required")
        set_pin(args.path, args.editor, args.kind, args.action == "pin")
        return 0
    pins = [row for row in load_pins() if os.path.exists(str(row.get("path", "")))]
    pinned_paths = {str(row["path"]) for row in pins}
    recent = collect(max(1, min(args.limit, 100)), pinned_paths)
    payload = {
        "pinned": pins,
        "recent": recent,
        "defaultEditor": preferred_editor(pins + recent),
        "version": manifest_version(),
    }
    if not write_payload(payload):
        print("recent projects output exceeded limit", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
