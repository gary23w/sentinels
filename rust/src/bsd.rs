//! FreeBSD: what is running (asked of the kernel), what is connected (sockstat), a watch for program starts, and
//! the hands.
//!
//! FreeBSD gives a program no notice of process starts without a kernel module, so the agent asks for the list of
//! running programs many times a second (one cheap question to the kernel) and reads only the ones that were not
//! there before.

#![cfg(target_os = "freebsd")]

use crate::bsdproc;
use crate::linux::Snap;
use crate::parse::{parse_sockstat, Conn, Proc};
use crate::respond;
use crate::tool::{run, watch_starts};
pub use crate::tool::{Looked, Shared};
use crate::watch::{Hands, Sensor};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc::Sender;
use std::time::Duration;

pub const SYSTEM: &str = "freebsd";

fn base(path: &str) -> String {
    path.rsplit('/').next().unwrap_or("").to_string()
}

/// Every running process id, in one question.
pub fn pids() -> HashSet<u32> {
    bsdproc::table().into_iter().map(|(pid, _, _)| pid).collect()
}

/// A process by the program file it runs; the kernel's own, which have none, by the name the kernel gives them.
fn identity(pid: u32, parent: u32, short: String) -> Proc {
    let path = bsdproc::path_of(pid);
    let name = if path.is_empty() { short } else { base(&path) };
    Proc { pid, ppid: parent, name, path, started: 0 }
}

/// One program that has just started: who it is, who started it, and its command line.
pub fn snapshot(pid: u32) -> Option<Snap> {
    let (parent, short) = bsdproc::one(pid)?;
    let proc = identity(pid, parent, short);
    let above = if parent > 1 { bsdproc::one(parent).map(|(grandparent, short)| identity(parent, grandparent, short).name).unwrap_or_default() } else { String::new() };
    Some(Snap { proc, cmdline: bsdproc::line_of(pid), parent: above, jumped: false, handed: false })
}

fn processes() -> Vec<Proc> {
    let mut found: Vec<Proc> = bsdproc::table().into_iter().map(|(pid, parent, short)| identity(pid, parent, short)).collect();
    found.sort_by_key(|proc| proc.pid);
    found
}

/// Ask the machine what is running and connected, and keep the answers for the next look.
pub fn refresh_now(shared: &Shared) {
    let procs = processes();
    let ask = |kind: &str| run(&["/usr/bin/sockstat", "-46", kind, "-P", "tcp"], None, Duration::from_secs(20)).unwrap_or_default();
    // Which programs accept connections: a shell one of them starts is judged like a shell under a web server.
    let (conns, listening) = parse_sockstat(&ask("-c"), &ask("-l"));
    if let Ok(mut looked) = shared.lock() {
        looked.procs = procs;
        looked.conns = conns;
        looked.listening = listening;
    }
}

/// Only what is running: for the look that follows a stop, which needs no new list of connections.
pub fn refresh_processes(shared: &Shared) {
    let procs = processes();
    if let Ok(mut looked) = shared.lock() {
        looked.procs = procs;
    }
}

pub fn background(_shared: &Shared) {}

pub struct Live {
    shared: Shared,
}

pub fn sensor(shared: Shared) -> Live {
    Live { shared }
}

impl Sensor for Live {
    fn system(&self) -> &str {
        SYSTEM
    }
    fn processes(&mut self) -> Vec<Proc> {
        self.shared.lock().map(|looked| looked.procs.clone()).unwrap_or_default()
    }
    fn running_now(&mut self) -> Vec<Proc> {
        processes()
    }
    fn connections(&mut self) -> Vec<Conn> {
        self.shared.lock().map(|looked| looked.conns.clone()).unwrap_or_default()
    }
    fn command_lines(&mut self, pids: &[u32]) -> HashMap<u32, String> {
        pids.iter().take(16).map(|pid| (*pid, bsdproc::line_of(*pid))).filter(|(_, line)| !line.is_empty()).collect()
    }
    fn file_age(&mut self, path: &str, now: f64) -> Option<f64> {
        use std::os::unix::fs::MetadataExt;
        if path.is_empty() {
            return None;
        }
        std::fs::metadata(path).ok().map(|meta| (now - meta.ctime() as f64).trunc().max(0.0))
    }
    fn listening(&self) -> HashSet<u32> {
        self.shared.lock().map(|looked| looked.listening.clone()).unwrap_or_default()
    }
}

/// The watch for program starts. It only looks; nothing waits on it.
pub struct Feeds;

impl Feeds {
    pub fn start(starts: Sender<Snap>) -> Feeds {
        watch_starts(pids, snapshot, true, starts);
        Feeds
    }

    pub fn open(&self) -> bool {
        true
    }

    /// The kernel's own process feed: there is none here.
    pub fn process_feed(&self) -> bool {
        false
    }

    pub fn step_ms(&self) -> u64 {
        50
    }

    pub fn pump(&mut self) -> bool {
        false
    }
}

/// There is no instant notice of a changed startup place here: startup places are read at every look.
pub fn startup_signal(_folders: &[PathBuf], _changed: Sender<()>) -> std::io::Result<usize> {
    Err(std::io::Error::new(std::io::ErrorKind::Unsupported, "not available on this system"))
}

/// Freeze, release and end with signals; refuse addresses with one blackhole host route each.
#[derive(Default)]
pub struct RealHands;

/// The routes this agent has added, whichever of its hands added them: one memory for the whole process, so any
/// of them can take a route away again.
fn routes() -> &'static std::sync::Mutex<HashSet<String>> {
    static CELL: std::sync::OnceLock<std::sync::Mutex<HashSet<String>>> = std::sync::OnceLock::new();
    CELL.get_or_init(Default::default)
}

impl Hands for RealHands {
    fn suspend(&mut self, pid: u32) -> bool {
        respond::suspend(pid)
    }
    fn resume(&mut self, pid: u32) -> bool {
        respond::resume(pid)
    }
    fn kill(&mut self, pid: u32) -> bool {
        respond::kill(pid)
    }
    /// A blackhole host route per address: nothing sent to it leaves the machine, so no connection in either
    /// direction can complete. Routes are ours to delete and do not survive a restart. No firewall rule is
    /// written and no firewall has to be switched on.
    fn block(&mut self, addresses: &[String]) -> Option<bool> {
        let wanted: HashSet<String> = addresses.iter().cloned().collect();
        let mut done = true;
        let Ok(mut held) = routes().lock() else { return Some(false) };
        let mut gone: Vec<String> = held.difference(&wanted).cloned().collect();
        gone.sort();
        for address in gone {
            let mut arguments = vec!["/sbin/route", "-n", "delete"];
            if address.contains(':') {
                arguments.push("-inet6");
            }
            arguments.extend(["-host", address.as_str()]);
            run(&arguments, None, Duration::from_secs(15));
            held.remove(&address);
        }
        let mut new: Vec<String> = wanted.difference(&held).cloned().collect();
        new.sort();
        for address in new {
            let mut arguments = vec!["/sbin/route", "-n", "add"];
            if address.contains(':') {
                arguments.push("-inet6");
            }
            arguments.extend(["-host", address.as_str(), if address.contains(':') { "::1" } else { "127.0.0.1" }, "-blackhole"]);
            if run(&arguments, None, Duration::from_secs(15)).is_some() {
                held.insert(address);
            } else {
                done = false;
            }
        }
        Some(done)
    }
}
