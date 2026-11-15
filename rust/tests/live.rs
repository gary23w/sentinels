//! Checks that change the machine they run on. A plain `cargo test` never runs them: each is marked `ignore` and
//! is started by name, by hand or by the hosted checks, on a machine made for it.
//!
//!   GARRETT_LIVE_STATE   a folder for the cleaner's records and quarantine
//!   GARRETT_LIVE_FILES   the program files to clean up after, separated by `;`
//!
//!   GARRETT_LIVE_ADDRESS a public address to refuse and let through again (it must answer on port 80)
//!
//!   cargo test --release --test live -- --ignored live_clean
//!   cargo test --release --test live -- --ignored live_restore
//!   cargo test --release --test live -- --ignored live_block

const KEY: &str = "0123456789abcdef0123456789abcdef";

fn state() -> std::path::PathBuf {
    std::path::PathBuf::from(std::env::var("GARRETT_LIVE_STATE").expect("GARRETT_LIVE_STATE"))
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs_f64()
}

/// Take the named program files away and switch off whatever would start them again.
#[test]
#[ignore]
fn live_clean() {
    let files: Vec<String> = std::env::var("GARRETT_LIVE_FILES").expect("GARRETT_LIVE_FILES").split(';').filter(|file| !file.is_empty()).map(str::to_string).collect();
    #[cfg(windows)]
    let steps = garrett::clean_win::Cleaner::new(&state()).clean(KEY, &files, &[], now());
    #[cfg(unix)]
    let steps = garrett::clean::Cleaner::new(if cfg!(target_os = "macos") { "macos" } else { "linux" }, &state(), None, false).clean(KEY, &files, &[], now() - 600.0, now());
    for step in &steps {
        println!("{} {}: {}", step["action"].as_str().unwrap_or(""), step["kind"].as_str().unwrap_or(""), step["where"].as_str().unwrap_or(""));
    }
    assert!(!steps.is_empty(), "nothing was cleaned");
}

/// Put everything back.
#[test]
#[ignore]
fn live_restore() {
    #[cfg(windows)]
    let (back, left) = garrett::clean_win::Cleaner::new(&state()).restore(KEY, now());
    #[cfg(unix)]
    let (back, left) = garrett::clean::Cleaner::new(if cfg!(target_os = "macos") { "macos" } else { "linux" }, &state(), None, false).restore(KEY, now());
    println!("{back} put back, {left} left");
    assert!(back > 0 && left == 0, "restore did not put everything back");
}

/// Fleet blocking, with the agent's own hands: an address that answers is refused, then let through again.
#[test]
#[ignore]
fn live_block() {
    use garrett::watch::Hands;
    let address = std::env::var("GARRETT_LIVE_ADDRESS").expect("GARRETT_LIVE_ADDRESS");
    let target: std::net::SocketAddr = format!("{address}:80").parse().expect("an address");
    let reach = || std::net::TcpStream::connect_timeout(&target, std::time::Duration::from_secs(6)).is_ok();
    let mut hands = garrett::machine::RealHands::default();
    let before = reach();
    let blocked = hands.block(&[address.clone()]);
    let during = reach();
    let cleared = hands.block(&[]);
    let after = reach();
    println!("before {before} | blocked {blocked:?} | during {during} | cleared {cleared:?} | after {after}");
    assert!(before, "the test address did not answer to begin with");
    assert!(blocked == Some(true) && !during && cleared == Some(true) && after, "fleet blocking did not behave as expected");
}
