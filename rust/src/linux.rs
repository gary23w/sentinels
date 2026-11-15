//! What is running on a Linux machine, read from /proc.
//!
//! The folder to read is a parameter, so the same code is proven against recorded /proc trees
//! (tests/fixtures/proc.jsonl) and then run against the real one.

use crate::parse::Proc;
use crate::score::{unix_writable, DIRECTORY_TOOLS, INTERPRETER_PREFIXES, SHELLS};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// A program that has just started: who it is, its command line, and the name of what started it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snap {
    pub proc: Proc,
    pub cmdline: String,
    pub parent: String,
}

fn base(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn lossy(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

/// Whether a program that has just started is one worth reading up on at all: a shell, a script interpreter, a
/// directory tool, or anything started from a folder any program can write to. On a machine starting thousands
/// of programs a second nearly all of them are not, and they must cost next to nothing.
pub fn exec_worth(path: &str) -> bool {
    let name = base(path).to_lowercase();
    SHELLS.contains(&name.as_str()) || INTERPRETER_PREFIXES.iter().any(|prefix| name.starts_with(prefix)) || DIRECTORY_TOOLS.contains(&name.as_str()) || unix_writable().is_match(path)
}

pub struct LinuxSensor {
    pub proc: PathBuf,
    seen: Option<HashSet<u32>>,
}

impl LinuxSensor {
    pub fn new(proc: &Path) -> LinuxSensor {
        LinuxSensor { proc: proc.to_path_buf(), seen: None }
    }

    /// (name in brackets, the fields after it) from one process's `stat`.
    fn stat(&self, pid: u32) -> Option<(String, Vec<String>)> {
        let raw = lossy(&std::fs::read(self.proc.join(pid.to_string()).join("stat")).ok()?);
        let (open, close) = (raw.find('(')?, raw.rfind(')')?);
        if close < open {
            return None;
        }
        let rest = raw.get(close + 2..).unwrap_or("");
        Some((raw[open + 1..close].to_string(), rest.split_whitespace().map(str::to_string).collect()))
    }

    fn exe(&self, pid: u32) -> String {
        std::fs::read_link(self.proc.join(pid.to_string()).join("exe")).map(|path| path.to_string_lossy().into_owned()).unwrap_or_default()
    }

    fn pids(&self) -> Option<HashSet<u32>> {
        let mut found = HashSet::new();
        for entry in std::fs::read_dir(&self.proc).ok()? {
            let Ok(entry) = entry else { continue };
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if !name.is_empty() && name.chars().all(|c| c.is_ascii_digit()) {
                if let Ok(pid) = name.parse() {
                    found.insert(pid);
                }
            }
        }
        Some(found)
    }

    fn identity(&self, pid: u32) -> Option<Proc> {
        let (comm, fields) = self.stat(pid)?;
        let path = self.exe(pid);
        let ppid: u32 = fields.get(1)?.parse().ok()?;
        let started: u64 = fields.get(19)?.parse().ok()?;
        let name = if base(&path).is_empty() { comm } else { base(&path).to_string() };
        Some(Proc { pid, ppid, name, path, started })
    }

    /// Every running process, lowest id first. One that ends while being read is simply not listed.
    pub fn processes(&self) -> Vec<Proc> {
        let mut pids: Vec<u32> = self.pids().unwrap_or_default().into_iter().collect();
        pids.sort_unstable();
        pids.into_iter().filter_map(|pid| self.identity(pid)).collect()
    }

    fn cmdline(&self, pid: u32) -> Option<String> {
        let mut raw = std::fs::read(self.proc.join(pid.to_string()).join("cmdline")).ok()?;
        raw.truncate(4096);
        for byte in raw.iter_mut() {
            if *byte == 0 {
                *byte = b' ';
            }
        }
        Some(lossy(&raw))
    }

    /// One program that has just started. `None` when it is already gone.
    pub fn snapshot(&self, pid: u32) -> Option<Snap> {
        let proc = self.identity(pid)?;
        let parent = base(&self.exe(proc.ppid)).to_string();
        let cmdline = self.cmdline(pid)?.trim().to_string();
        Some(Snap { proc, cmdline, parent })
    }

    /// Processes that appeared since the last call: one directory listing, then only the new ones are read.
    pub fn fresh(&mut self) -> Vec<Snap> {
        let Some(now) = self.pids() else { return Vec::new() };
        let mut new: Vec<u32> = match &self.seen {
            Some(before) => now.difference(before).copied().collect(),
            None => Vec::new(), // the first look: what is already running is not news
        };
        self.seen = Some(now);
        new.sort_unstable();
        new.into_iter().take(256).filter_map(|pid| self.snapshot(pid)).collect()
    }

    /// The command lines of up to sixteen processes, as they are, for those still running.
    pub fn command_lines(&self, pids: &[u32]) -> Vec<(u32, String)> {
        pids.iter().take(16).filter_map(|pid| self.cmdline(*pid).map(|line| (*pid, line))).collect()
    }
}
