//! The `garrett` command as a person runs it, on a made-up state folder: what it says.

use garrett::agent::lower_mode;
use std::path::{Path, PathBuf};
use std::process::Command;

fn folder(tag: &str) -> PathBuf {
    let folder = std::env::temp_dir().join(format!("garrett-commands-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    folder
}

/// A machine enrolled with a service that allowed it `mode`.
fn enrolled(folder: &Path, mode: &str) {
    let saved = serde_json::json!({"server": "https://sentinel.example", "pin": "", "token": "a".repeat(64), "device_id": "d", "salt": "b".repeat(64), "mode": mode, "fallback": "kill"});
    std::fs::write(folder.join("agent.json"), saved.to_string()).unwrap();
}

fn garrett(folder: &Path, arguments: &[&str]) -> (i32, String) {
    let done = Command::new(env!("CARGO_BIN_EXE_garrett")).arg("--state-dir").arg(folder).args(arguments).env_remove("SENTINEL_MODE").output().unwrap();
    (done.status.code().unwrap_or(-1), String::from_utf8_lossy(&done.stdout).into_owned())
}

#[test]
fn the_mode_a_machines_configuration_asks_for_can_lower_what_its_service_allows_and_never_raise_it() {
    assert_eq!(lower_mode("kill", "pause"), "pause");
    assert_eq!(lower_mode("kill", "report"), "report");
    assert_eq!(lower_mode("kill", "decide"), "decide");
    assert_eq!(lower_mode("kill", "kill"), "kill");
    assert_eq!(lower_mode("pause", "kill"), "pause");
    assert_eq!(lower_mode("report", "decide"), "report");
    assert_eq!(lower_mode("kill", "everything"), "report", "a mode that is not understood is the least");

    let folder = folder("mode");
    enrolled(&folder, "kill");
    assert_eq!(garrett(&folder, &["status"]), (0, "Enrolled with https://sentinel.example. Mode: kill.\n".to_string()));
    assert_eq!(garrett(&folder, &["status", "--mode", "report"]), (0, "Enrolled with https://sentinel.example. Mode: report (this machine's configuration asks for report; its service allows kill).\n".to_string()));
    enrolled(&folder, "pause");
    assert_eq!(garrett(&folder, &["status", "--mode", "kill"]), (0, "Enrolled with https://sentinel.example. Mode: pause.\n".to_string()));
    let _ = std::fs::remove_dir_all(&folder);
}
