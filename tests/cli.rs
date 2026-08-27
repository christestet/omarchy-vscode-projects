use std::fs;
use std::process::Command;

use serde_json::Value;

fn helper() -> Command {
    Command::new(env!("CARGO_BIN_EXE_vsc-recent-projects"))
}

#[test]
fn pin_list_and_unpin_all_keep_the_qml_json_contract() {
    let temp = tempfile::tempdir().unwrap();
    let project = temp.path().join("favorite");
    fs::create_dir(&project).unwrap();
    let config = temp.path().join("config");
    let shared = temp.path().join("shared");

    let status = helper()
        .env("XDG_CONFIG_HOME", &config)
        .arg("pin")
        .arg("--path")
        .arg(&project)
        .arg("--editor")
        .arg("codium")
        .arg("--kind")
        .arg("folder")
        .status()
        .unwrap();
    assert!(status.success());

    let output = helper()
        .env("XDG_CONFIG_HOME", &config)
        .env("VSCODE_SHARED_DATA_HOME", &shared)
        .args(["list", "--limit", "3"])
        .output()
        .unwrap();
    assert!(output.status.success());
    let payload: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(payload["version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(
        payload["pinned"][0]["path"],
        project.to_string_lossy().as_ref()
    );
    assert_eq!(payload["pinned"][0]["editor"], "codium");
    assert!(payload["recent"].is_array());
    assert!(payload["defaultEditor"].is_string());

    let status = helper()
        .env("XDG_CONFIG_HOME", &config)
        .arg("unpin-all")
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn pin_requires_a_path() {
    let output = helper().arg("pin").output().unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&output.stderr).contains("--path is required"));
}
