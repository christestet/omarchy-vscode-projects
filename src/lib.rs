use std::collections::HashSet;
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, symlink};
use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use rusqlite::limits::Limit;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

const EDITORS: [Editor; 4] = [
    Editor::new("code", "Code", ".vscode-shared"),
    Editor::new(
        "code-insiders",
        "Code - Insiders",
        ".vscode-insiders-shared",
    ),
    Editor::new("codium", "VSCodium", ".vscodium-shared"),
    Editor::new("code-oss", "Code - OSS", ".vscode-oss-shared"),
];

// VS Code state is externally replaceable input. Bound every stage so a
// corrupt profile cannot monopolize the long-running shell through its helper.
pub const MAX_JSON_BYTES: usize = 1024 * 1024;
pub const MAX_DATABASE_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_SQL_VALUE_BYTES: usize = MAX_JSON_BYTES;
pub const MAX_SQL_STEPS: i32 = 100_000;
pub const MAX_RECENT_ENTRIES: usize = 500;
pub const MAX_PATH_CHARS: usize = 2048;
pub const MAX_NAME_CHARS: usize = 256;
pub const MAX_PINS: usize = 100;
pub const MAX_OUTPUT_BYTES: usize = 512 * 1024;

#[derive(Clone, Copy)]
struct Editor {
    command: &'static str,
    config_dir: &'static str,
    shared_dir: &'static str,
}

impl Editor {
    const fn new(
        command: &'static str,
        config_dir: &'static str,
        shared_dir: &'static str,
    ) -> Self {
        Self {
            command,
            config_dir,
            shared_dir,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct Project {
    pub name: String,
    pub path: String,
    pub editor: String,
    pub kind: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ListPayload {
    pub pinned: Vec<Project>,
    pub recent: Vec<Project>,
    pub default_editor: String,
    pub version: &'static str,
}

pub fn read_regular_file(path: &Path, max_bytes: usize) -> Option<String> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > max_bytes as u64 {
        return None;
    }

    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    Read::by_ref(&mut file)
        .take(max_bytes.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() > max_bytes {
        return None;
    }
    String::from_utf8(bytes).ok()
}

pub fn read_json(path: &Path, max_bytes: usize) -> Option<Value> {
    serde_json::from_str(&read_regular_file(path, max_bytes)?).ok()
}

pub const fn version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn config_path() -> PathBuf {
    let root = env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".config"));
    root.join("omarchy/vscode-projects.json")
}

fn shared_data_home() -> PathBuf {
    env::var_os("VSCODE_SHARED_DATA_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(home_dir)
}

fn truncate_chars(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn percent_decode(value: &str) -> Option<String> {
    let input = value.as_bytes();
    let mut output = Vec::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        if input[index] == b'%' {
            let high = hex_value(*input.get(index + 1)?)?;
            let low = hex_value(*input.get(index + 2)?)?;
            output.push((high << 4) | low);
            index += 3;
        } else {
            output.push(input[index]);
            index += 1;
        }
    }
    if output.contains(&0) {
        return None;
    }
    String::from_utf8(output).ok()
}

fn file_uri_path(uri: &str) -> Option<String> {
    let remainder = uri.strip_prefix("file://")?;
    let slash = remainder.find('/').unwrap_or(remainder.len());
    let authority = &remainder[..slash];
    if !authority.is_empty() && authority != "localhost" {
        return None;
    }
    let mut encoded_path = &remainder[slash..];
    if let Some(end) = encoded_path.find(['?', '#']) {
        encoded_path = &encoded_path[..end];
    }
    if encoded_path.is_empty() {
        return None;
    }
    percent_decode(encoded_path)
}

fn lexical_absolute(path: &Path) -> Option<PathBuf> {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir().ok()?.join(path)
    };
    let mut normalized = PathBuf::from("/");
    for component in absolute.components() {
        match component {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            Component::Normal(part) => normalized.push(part),
            Component::Prefix(_) => return None,
        }
    }
    Some(normalized)
}

pub fn local_path(value: &str) -> Option<String> {
    if value.is_empty() || value.chars().count() > MAX_PATH_CHARS {
        return None;
    }

    let decoded = if value.starts_with("file://") {
        file_uri_path(value)?
    } else if value.contains("://") {
        return None;
    } else {
        value.to_owned()
    };

    let expanded = if decoded == "~" {
        home_dir()
    } else if let Some(suffix) = decoded.strip_prefix("~/") {
        home_dir().join(suffix)
    } else if decoded.starts_with('~') {
        return None;
    } else {
        PathBuf::from(decoded)
    };
    Some(lexical_absolute(&expanded)?.to_string_lossy().into_owned())
}

fn project_name(path: &str) -> String {
    let path = Path::new(path);
    let candidate = if path.extension().and_then(|value| value.to_str()) == Some("code-workspace") {
        path.file_stem()
    } else {
        path.file_name()
    };
    candidate
        .map(|value| value.to_string_lossy().into_owned())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| path.to_string_lossy().into_owned())
}

fn project_from_value(value: &Value) -> Option<Project> {
    let row = value.as_object()?;
    let path = local_path(row.get("path")?.as_str()?)?;
    let fallback = project_name(&path);
    let name = row
        .get("name")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or(&fallback);
    let editor = row.get("editor").and_then(Value::as_str).unwrap_or("code");
    let kind = row.get("kind").and_then(Value::as_str).unwrap_or("folder");
    Some(Project {
        name: truncate_chars(name, MAX_NAME_CHARS),
        path,
        editor: truncate_chars(editor, 64),
        kind: truncate_chars(kind, 64),
    })
}

pub fn load_pins_from(path: &Path) -> Vec<Project> {
    let Some(Value::Object(root)) = read_json(path, MAX_JSON_BYTES) else {
        return Vec::new();
    };
    root.get("pinned")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(MAX_PINS)
        .filter_map(project_from_value)
        .collect()
}

pub fn load_pins() -> Vec<Project> {
    load_pins_from(&config_path())
}

pub fn save_pins_to(path: &Path, rows: &[Project]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "pin path has no parent"))?;
    fs::create_dir_all(parent)?;
    let payload = serde_json::json!({
        "pinned": rows.iter().take(MAX_PINS).collect::<Vec<_>>()
    });
    let mut encoded = serde_json::to_vec_pretty(&payload)?;
    encoded.push(b'\n');

    let mut temporary = tempfile::NamedTempFile::new_in(parent)?;
    temporary.write_all(&encoded)?;
    temporary.as_file().sync_all()?;
    temporary
        .persist(path)
        .map_err(|error| error.error)
        .map(|_| ())
}

pub fn set_pin_at(
    config: &Path,
    path: &str,
    editor: &str,
    kind: &str,
    pinned: bool,
) -> io::Result<()> {
    let normalized = local_path(path)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid project path"))?;
    let mut rows: Vec<Project> = load_pins_from(config)
        .into_iter()
        .filter(|row| row.path != normalized)
        .collect();
    if pinned {
        rows.insert(
            0,
            Project {
                name: truncate_chars(&project_name(&normalized), MAX_NAME_CHARS),
                path: normalized,
                editor: truncate_chars(editor, 64),
                kind: truncate_chars(kind, 64),
            },
        );
    }
    save_pins_to(config, &rows)
}

pub fn set_pin(path: &str, editor: &str, kind: &str, pinned: bool) -> io::Result<()> {
    set_pin_at(&config_path(), path, editor, kind, pinned)
}

pub fn clear_pins() -> io::Result<()> {
    save_pins_to(&config_path(), &[])
}

pub fn recent_entries(value: &Value) -> Vec<(String, &'static str)> {
    let Some(entries) = value.get("entries").and_then(Value::as_array) else {
        return Vec::new();
    };
    entries
        .iter()
        .take(MAX_RECENT_ENTRIES)
        .filter_map(|entry| {
            let row = entry.as_object()?;
            if let Some(folder) = row.get("folderUri").and_then(Value::as_str)
                && !folder.is_empty()
            {
                return Some((folder.to_owned(), "folder"));
            }
            let workspace = match row.get("workspace") {
                Some(Value::Object(workspace)) => workspace
                    .get("configPath")
                    .or_else(|| workspace.get("path"))
                    .and_then(Value::as_str),
                Some(Value::String(workspace)) => Some(workspace.as_str()),
                _ => None,
            }
            .or_else(|| row.get("configPath").and_then(Value::as_str));
            workspace
                .filter(|value| !value.is_empty())
                .map(|value| (value.to_owned(), "workspace"))
        })
        .collect()
}

struct DatabaseSnapshot {
    files: Vec<(String, File)>,
}

fn open_database_snapshot(database: &Path, max_bytes: u64) -> Option<DatabaseSnapshot> {
    let mut files = Vec::new();
    // Hold the checked files open for the entire SQLite read. O_NOFOLLOW closes
    // the path-replacement gap between validation and use.
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut path = database.as_os_str().to_os_string();
        path.push(suffix);
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(PathBuf::from(path))
        {
            Ok(file) => file,
            Err(error) if !suffix.is_empty() && error.kind() == io::ErrorKind::NotFound => {
                continue;
            }
            Err(_) => return None,
        };
        let metadata = file.metadata().ok()?;
        if !metadata.is_file() || metadata.len() > max_bytes {
            return None;
        }
        files.push((suffix.to_owned(), file));
    }
    Some(DatabaseSnapshot { files })
}

fn history_from_db_with_limits(
    database: &Path,
    database_max_bytes: u64,
    sql_value_max_bytes: usize,
    max_sql_steps: i32,
) -> Option<Value> {
    let snapshot = open_database_snapshot(database, database_max_bytes)?;
    let staged = tempfile::Builder::new()
        .prefix("vscode-projects-")
        .tempdir()
        .ok()?;
    let staged_database = staged.path().join("state.vscdb");
    // SQLite discovers WAL/SHM files by adjacent names. A private namespace of
    // /proc/self/fd links preserves that contract while binding every name to
    // the descriptor snapshot above.
    for (suffix, file) in &snapshot.files {
        let mut link = staged_database.as_os_str().to_os_string();
        link.push(suffix);
        symlink(format!("/proc/self/fd/{}", file.as_raw_fd()), link).ok()?;
    }

    let uri = format!("file:{}?mode=ro", staged_database.to_string_lossy());
    let connection = Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    connection.busy_timeout(Duration::from_millis(200)).ok()?;
    connection
        .set_limit(Limit::SQLITE_LIMIT_LENGTH, sql_value_max_bytes as i32)
        .ok()?;
    connection
        .progress_handler(max_sql_steps.max(1), Some(|| true))
        .ok()?;

    let encoded: Option<Vec<u8>> = connection
        .query_row(
            "SELECT CAST(value AS BLOB) FROM ItemTable WHERE key = ?1 AND length(CAST(value AS BLOB)) <= ?2 LIMIT 1",
            params!["history.recentlyOpenedPathsList", sql_value_max_bytes as i64],
            |row| row.get(0),
        )
        .optional()
        .ok()?;
    serde_json::from_slice(&encoded?).ok()
}

pub fn history_from_db(database: &Path) -> Option<Value> {
    history_from_db_with_limits(
        database,
        MAX_DATABASE_BYTES,
        MAX_SQL_VALUE_BYTES,
        MAX_SQL_STEPS,
    )
}

fn add_project(
    rows: &mut Vec<Project>,
    seen: &mut HashSet<String>,
    value: &str,
    editor: &str,
    kind: &str,
) {
    let Some(path) = local_path(value) else {
        return;
    };
    if seen.contains(&path) || !Path::new(&path).exists() {
        return;
    }
    seen.insert(path.clone());
    rows.push(Project {
        name: project_name(&path),
        path,
        editor: editor.to_owned(),
        kind: kind.to_owned(),
    });
}

fn collect_with_roots(
    limit: usize,
    excluded: &HashSet<String>,
    config_root: &Path,
    shared_root: &Path,
) -> Vec<Project> {
    let limit = limit.min(100);
    if limit == 0 {
        return Vec::new();
    }
    let mut rows = Vec::with_capacity(limit);
    let mut seen = excluded.clone();
    for editor in EDITORS {
        if rows.len() >= limit {
            break;
        }
        let user_dir = config_root.join(editor.config_dir).join("User");
        // Current releases share MRU state outside the editor profile. Retain
        // the editor-local database and legacy JSON as compatibility fallbacks.
        let mut data = history_from_db(
            &shared_root
                .join(editor.shared_dir)
                .join("sharedStorage/state.vscdb"),
        );
        if data.is_none() {
            data = history_from_db(&user_dir.join("globalStorage/state.vscdb"));
        }
        if data.is_none() {
            data = read_json(&user_dir.join("globalStorage/storage.json"), MAX_JSON_BYTES);
        }
        let Some(data) = data else {
            continue;
        };
        for (value, kind) in recent_entries(&data) {
            add_project(&mut rows, &mut seen, &value, editor.command, kind);
            if rows.len() >= limit {
                break;
            }
        }
    }
    rows
}

pub fn collect(limit: usize, excluded: &HashSet<String>) -> Vec<Project> {
    let config_root = env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".config"));
    collect_with_roots(limit, excluded, &config_root, &shared_data_home())
}

fn command_available(command: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path).any(|directory| {
        fs::metadata(directory.join(command))
            .map(|metadata| metadata.is_file() && metadata.mode() & 0o111 != 0)
            .unwrap_or(false)
    })
}

fn preferred_editor_with<F>(rows: &[Project], available: F) -> String
where
    F: Fn(&str) -> bool,
{
    let available_editors: Vec<&str> = EDITORS
        .iter()
        .map(|editor| editor.command)
        .filter(|command| available(command))
        .collect();
    rows.iter()
        .map(|row| row.editor.as_str())
        .find(|editor| available_editors.contains(editor))
        .or_else(|| available_editors.first().copied())
        .unwrap_or("code")
        .to_owned()
}

pub fn preferred_editor(rows: &[Project]) -> String {
    preferred_editor_with(rows, command_available)
}

pub fn list_payload(limit: usize) -> ListPayload {
    let pinned: Vec<Project> = load_pins()
        .into_iter()
        .filter(|row| Path::new(&row.path).exists())
        .collect();
    let excluded: HashSet<String> = pinned.iter().map(|row| row.path.clone()).collect();
    let recent = collect(limit.clamp(1, 100), &excluded);
    let all: Vec<Project> = pinned.iter().chain(&recent).cloned().collect();
    ListPayload {
        pinned,
        recent,
        default_editor: preferred_editor(&all),
        version: version(),
    }
}

pub fn write_payload_to<W: Write, T: Serialize>(mut output: W, payload: &T) -> io::Result<bool> {
    let mut encoded = serde_json::to_vec(payload)?;
    encoded.push(b'\n');
    if encoded.len() > MAX_OUTPUT_BYTES {
        return Ok(false);
    }
    output.write_all(&encoded)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use serde_json::json;
    use std::os::unix::fs::symlink;

    fn project(path: &Path, editor: &str) -> Project {
        Project {
            name: project_name(&path.to_string_lossy()),
            path: path.to_string_lossy().into_owned(),
            editor: editor.to_owned(),
            kind: "folder".to_owned(),
        }
    }

    #[test]
    fn package_and_plugin_versions_match() {
        let manifest = read_json(
            &Path::new(env!("CARGO_MANIFEST_DIR")).join("manifest.json"),
            MAX_JSON_BYTES,
        )
        .unwrap();
        assert_eq!(manifest["version"].as_str(), Some(version()));
    }

    #[test]
    fn file_uri_is_decoded_and_remote_uri_is_rejected() {
        assert_eq!(
            local_path("file:///tmp/hello%20world").as_deref(),
            Some("/tmp/hello world")
        );
        assert!(local_path("vscode-remote://ssh-remote/project").is_none());
        assert!(local_path("file://server/tmp/project").is_none());
    }

    #[test]
    fn regular_file_guards_size_and_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let large = temp.path().join("large.json");
        fs::write(&large, b"                 ").unwrap();
        assert!(read_json(&large, 16).is_none());

        let target = temp.path().join("target.json");
        fs::write(&target, b"{}").unwrap();
        let link = temp.path().join("link.json");
        symlink(&target, &link).unwrap();
        assert!(read_json(&link, MAX_JSON_BYTES).is_none());
    }

    #[test]
    fn excessively_nested_json_is_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("deep.json");
        fs::write(&path, format!("{}0{}", "[".repeat(1000), "]".repeat(1000))).unwrap();
        assert!(read_json(&path, MAX_JSON_BYTES).is_none());
    }

    #[test]
    fn sqlite_value_is_bounded() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().join("state.vscdb");
        let db = Connection::open(&database).unwrap();
        db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
            .unwrap();
        db.execute(
            "INSERT INTO ItemTable VALUES (?1, ?2)",
            params!["history.recentlyOpenedPathsList", "x".repeat(20)],
        )
        .unwrap();
        drop(db);
        assert!(
            history_from_db_with_limits(&database, MAX_DATABASE_BYTES, 16, MAX_SQL_STEPS).is_none()
        );
    }

    #[test]
    fn wal_backed_database_is_read_through_descriptor_snapshot() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().join("state.vscdb");
        let db = Connection::open(&database).unwrap();
        db.pragma_update(None, "journal_mode", "WAL").unwrap();
        db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
            .unwrap();
        db.execute(
            "INSERT INTO ItemTable VALUES (?1, ?2)",
            params![
                "history.recentlyOpenedPathsList",
                json!({"entries": [{"folderUri": "file:///tmp/project"}]}).to_string()
            ],
        )
        .unwrap();
        assert_eq!(
            history_from_db(&database),
            Some(json!({"entries": [{"folderUri": "file:///tmp/project"}]}))
        );
    }

    #[test]
    fn sqlite_source_path_may_contain_uri_metacharacters() {
        let temp = tempfile::tempdir().unwrap();
        let directory = temp.path().join("vscode?#");
        fs::create_dir(&directory).unwrap();
        let database = directory.join("state.vscdb");
        let db = Connection::open(&database).unwrap();
        db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
            .unwrap();
        db.execute(
            "INSERT INTO ItemTable VALUES (?1, ?2)",
            params!["history.recentlyOpenedPathsList", "{}"],
        )
        .unwrap();
        drop(db);
        assert_eq!(history_from_db(&database), Some(json!({})));
    }

    #[test]
    fn sqlite_guards_sidecar_size_and_database_symlinks() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().join("state.vscdb");
        fs::write(&database, b"").unwrap();
        fs::write(database.with_extension("vscdb-wal"), b"xxxxxxxxxxxxxxxxx").unwrap();
        assert!(open_database_snapshot(&database, 16).is_none());

        let actual = temp.path().join("actual.vscdb");
        fs::write(&actual, b"").unwrap();
        let link = temp.path().join("linked.vscdb");
        symlink(actual, &link).unwrap();
        assert!(history_from_db(&link).is_none());
    }

    #[test]
    fn recent_entries_are_ordered_schema_bound_and_bounded() {
        let mut entries = vec![
            json!({"folderUri": "/first"}),
            json!({"workspace": {"configPath": "/second.code-workspace"}}),
            json!({"nested": {"folderUri": "/ignored"}}),
        ];
        entries
            .extend((0..MAX_RECENT_ENTRIES).map(|index| json!({"folderUri": format!("/{index}")})));
        let rows = recent_entries(&json!({"entries": entries}));
        assert_eq!(rows[0], ("/first".to_owned(), "folder"));
        assert_eq!(rows[1], ("/second.code-workspace".to_owned(), "workspace"));
        assert_eq!(rows.len(), MAX_RECENT_ENTRIES - 1);
    }

    #[test]
    fn collect_prefers_shared_history_and_honors_limit() {
        let temp = tempfile::tempdir().unwrap();
        let current = temp.path().join("current");
        let legacy = temp.path().join("legacy");
        fs::create_dir(&current).unwrap();
        fs::create_dir(&legacy).unwrap();

        let shared = temp.path().join(".vscode-shared/sharedStorage/state.vscdb");
        fs::create_dir_all(shared.parent().unwrap()).unwrap();
        let db = Connection::open(shared).unwrap();
        db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
            .unwrap();
        db.execute(
            "INSERT INTO ItemTable VALUES (?1, ?2)",
            params![
                "history.recentlyOpenedPathsList",
                json!({"entries": [{"folderUri": current.to_string_lossy()}]}).to_string()
            ],
        )
        .unwrap();
        drop(db);

        let legacy_db = temp.path().join("Code/User/globalStorage/state.vscdb");
        fs::create_dir_all(legacy_db.parent().unwrap()).unwrap();
        let db = Connection::open(legacy_db).unwrap();
        db.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)", [])
            .unwrap();
        db.execute(
            "INSERT INTO ItemTable VALUES (?1, ?2)",
            params![
                "history.recentlyOpenedPathsList",
                json!({"entries": [{"folderUri": legacy.to_string_lossy()}]}).to_string()
            ],
        )
        .unwrap();
        drop(db);

        let rows = collect_with_roots(1, &HashSet::new(), temp.path(), temp.path());
        assert_eq!(rows, vec![project(&current, "code")]);
        assert!(collect_with_roots(0, &HashSet::new(), temp.path(), temp.path()).is_empty());
    }

    #[test]
    fn collect_falls_back_to_legacy_storage_json() {
        let temp = tempfile::tempdir().unwrap();
        let project_path = temp.path().join("project");
        fs::create_dir(&project_path).unwrap();
        let storage = temp.path().join("Code/User/globalStorage/storage.json");
        fs::create_dir_all(storage.parent().unwrap()).unwrap();
        fs::write(
            storage,
            json!({"entries": [{"folderUri": project_path.to_string_lossy()}]}).to_string(),
        )
        .unwrap();

        let rows = collect_with_roots(5, &HashSet::new(), temp.path(), temp.path());
        assert_eq!(rows, vec![project(&project_path, "code")]);
    }

    #[test]
    fn workspace_cache_is_not_scanned() {
        let temp = tempfile::tempdir().unwrap();
        let cache = temp
            .path()
            .join("Code/User/workspaceStorage/stale/workspace.json");
        fs::create_dir_all(cache.parent().unwrap()).unwrap();
        fs::write(cache, b"{\"folder\":\"/tmp\"}").unwrap();
        assert!(collect_with_roots(5, &HashSet::new(), temp.path(), temp.path()).is_empty());
    }

    #[test]
    fn pins_round_trip_and_fields_are_bounded() {
        let temp = tempfile::tempdir().unwrap();
        let favorite = temp.path().join("favorite");
        fs::create_dir(&favorite).unwrap();
        let config = temp.path().join("config/omarchy/vscode-projects.json");
        set_pin_at(
            &config,
            &favorite.to_string_lossy(),
            &"e".repeat(1000),
            &"k".repeat(1000),
            true,
        )
        .unwrap();
        let pins = load_pins_from(&config);
        assert_eq!(pins.len(), 1);
        assert_eq!(pins[0].path, favorite.to_string_lossy());
        assert_eq!(pins[0].editor.chars().count(), 64);
        assert_eq!(pins[0].kind.chars().count(), 64);

        set_pin_at(
            &config,
            &favorite.to_string_lossy(),
            "code",
            "folder",
            false,
        )
        .unwrap();
        assert!(load_pins_from(&config).is_empty());
    }

    #[test]
    fn pin_input_count_and_names_are_bounded() {
        let temp = tempfile::tempdir().unwrap();
        let config = temp.path().join("pins.json");
        let values: Vec<Value> = (0..MAX_PINS + 10)
            .map(|_| json!({"path": "/tmp", "name": "x".repeat(1000)}))
            .collect();
        fs::write(&config, json!({"pinned": values}).to_string()).unwrap();
        let pins = load_pins_from(&config);
        assert_eq!(pins.len(), MAX_PINS);
        assert_eq!(pins[0].name.chars().count(), MAX_NAME_CHARS);
    }

    #[test]
    fn preferred_editor_uses_project_affinity_then_first_available() {
        let rows = vec![Project {
            name: "Project".to_owned(),
            path: "/tmp".to_owned(),
            editor: "codium".to_owned(),
            kind: "folder".to_owned(),
        }];
        assert_eq!(
            preferred_editor_with(&rows, |command| command == "code" || command == "codium"),
            "codium"
        );
        assert_eq!(
            preferred_editor_with(&[], |command| command == "codium"),
            "codium"
        );
    }

    #[test]
    fn helper_output_is_bounded() {
        let mut output = Vec::new();
        assert!(write_payload_to(&mut output, &json!({"recent": []})).unwrap());
        assert!(output.len() < MAX_OUTPUT_BYTES);
        let oversized = "x".repeat(MAX_OUTPUT_BYTES);
        assert!(!write_payload_to(Vec::new(), &json!({"value": oversized})).unwrap());
    }
}
