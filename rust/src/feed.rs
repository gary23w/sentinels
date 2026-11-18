//! The kernel's process-start feed (netlink proc connector). Needs root; a daemon install has it.
//!
//! A command that lives for a few milliseconds is gone before any sampler looks. This thread is told about
//! every program start as it happens and reads that process's identity and command line at once.
//! It only listens: nothing on the machine waits for it.
//!
//! It is also told about every new process. One that is born belonging to an ordinary user is followed through
//! the programs it becomes, so that one which turns up as root without ever having been a program that grants
//! root is noticed (`LinuxSensor::jumped`), and so is one that becomes a root shell straight out of a program
//! that never turns into one (`LinuxSensor::handed`). A process born as root costs one question and is not followed.



use crate::linux::{exec_worth, LinuxSensor, Snap};
use crate::score::{is_shell, INTERPRETER_PREFIXES, WEB_SERVER_PREFIXES};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;

pub struct ExecFeed {
    pub starts: Receiver<Snap>,
    seen: Arc<AtomicU64>,
    caught: Arc<AtomicU64>,
    stopped: Arc<AtomicBool>,
}

fn put32(buffer: &mut Vec<u8>, value: u32) {
    buffer.extend_from_slice(&value.to_ne_bytes());
}

fn put16(buffer: &mut Vec<u8>, value: u16) {
    buffer.extend_from_slice(&value.to_ne_bytes());
}

fn word(data: &[u8], at: usize) -> u32 {
    u32::from_ne_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]])
}

/// An exec can replace a web server with a shell under the same PID. Its process parent then names the service
/// manager, while the image it just replaced is the source that matters for containment.
fn web_exec_source(previous: Option<&Path>, next: &str) -> Option<String> {
    let lowered = next.to_lowercase();
    if !is_shell(&lowered) && !INTERPRETER_PREFIXES.iter().any(|prefix| lowered.starts_with(prefix)) {
        return None;
    }
    let name = previous?.file_name()?.to_string_lossy().into_owned();
    WEB_SERVER_PREFIXES.iter().any(|prefix| name.to_lowercase().starts_with(prefix)).then_some(name)
}

impl ExecFeed {
    /// Start listening. Fails where the feed is not permitted (not root, some containers).
    pub fn open(proc: &Path) -> std::io::Result<ExecFeed> {
        Self::open_with(proc, None)
    }

    /// Send starts straight to the responders. The run loop must not add a polling delay before containment.
    pub fn open_to(proc: &Path, starts: Sender<Snap>) -> std::io::Result<ExecFeed> {
        Self::open_with(proc, Some(starts))
    }

    fn open_with(proc: &Path, direct: Option<Sender<Snap>>) -> std::io::Result<ExecFeed> {
        let own = std::process::id();
        let handle = unsafe { libc::socket(libc::AF_NETLINK, libc::SOCK_DGRAM | libc::SOCK_CLOEXEC, 11) }; // NETLINK_CONNECTOR
        if handle < 0 {
            return Err(std::io::Error::last_os_error());
        }
        let fail = |handle: libc::c_int| -> std::io::Error {
            let error = std::io::Error::last_os_error();
            unsafe { libc::close(handle) };
            error
        };
        let mut address: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
        address.nl_family = libc::AF_NETLINK as libc::sa_family_t;
        address.nl_pid = own;
        address.nl_groups = 1; // CN_IDX_PROC
        if unsafe { libc::bind(handle, &address as *const libc::sockaddr_nl as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_nl>() as libc::socklen_t) } != 0 {
            return Err(fail(handle));
        }
        // "Tell me about process events": a connector message carrying PROC_CN_MCAST_LISTEN.
        let mut body = Vec::new();
        for value in [1u32, 1, 0, 0] {
            put32(&mut body, value); // cn_msg: idx CN_IDX_PROC, val CN_VAL_PROC, seq, ack
        }
        put16(&mut body, 4); // length of what follows
        put16(&mut body, 0);
        put32(&mut body, 1); // PROC_CN_MCAST_LISTEN
        let mut message = Vec::new();
        put32(&mut message, 16 + body.len() as u32);
        put16(&mut message, 3); // NLMSG_DONE
        put16(&mut message, 0);
        put32(&mut message, 0);
        put32(&mut message, own);
        message.extend_from_slice(&body);
        if unsafe { libc::send(handle, message.as_ptr() as *const libc::c_void, message.len(), 0) } < 0 {
            return Err(fail(handle));
        }
        let wait = libc::timeval { tv_sec: 1, tv_usec: 0 };
        unsafe { libc::setsockopt(handle, libc::SOL_SOCKET, libc::SO_RCVTIMEO, &wait as *const libc::timeval as *const libc::c_void, std::mem::size_of::<libc::timeval>() as libc::socklen_t) };

        let (sender, starts) = channel();
        let (seen, caught, stopped) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)), Arc::new(AtomicBool::new(false)));
        let (seen_in, caught_in, stopped_in) = (seen.clone(), caught.clone(), stopped.clone());
        let sensor = LinuxSensor::new(proc);
        std::thread::Builder::new().name("garrett-feed".into()).spawn(move || {
            let mut data = [0u8; 4096];
            // Each followed process, and the programs it has been since it was born.
            let mut followed: HashMap<u32, Vec<PathBuf>> = HashMap::new();
            while !stopped_in.load(Ordering::Relaxed) {
                let got = unsafe { libc::recv(handle, data.as_mut_ptr() as *mut libc::c_void, data.len(), 0) };
                if got < 0 {
                    let error = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
                    if error == libc::EAGAIN || error == libc::EWOULDBLOCK || error == libc::EINTR || error == libc::ENOBUFS {
                        continue; // nothing in the last second, or a burst the kernel could not queue: keep listening
                    }
                    break;
                }
                let got = got as usize;
                if got >= 68 && word(&data, 36) == 1 {
                    // PROC_EVENT_FORK: a new process (a new thread of an old one is not news).
                    let (thread, born) = (word(&data, 60), word(&data, 64));
                    if thread == born {
                        if followed.len() >= 16384 {
                            followed.clear(); // nothing says when a process ends: start over rather than grow
                        }
                        match sensor.owner(born) {
                            Some(user) if user != 0 => followed.insert(born, Vec::new()),
                            _ => followed.remove(&born),
                        };
                    }
                    continue;
                }
                if got < 60 || word(&data, 36) != 2 {
                    continue; // not PROC_EVENT_EXEC
                }
                let pid = word(&data, 56); // the process (thread group) id
                seen_in.fetch_add(1, Ordering::Relaxed);
                let Ok(image) = std::fs::read_link(sensor.proc.join(pid.to_string()).join("exe")) else { continue };
                caught_in.fetch_add(1, Ordering::Relaxed);
                let worth = exec_worth(&image.to_string_lossy());
                let source = web_exec_source(followed.get(&pid).and_then(|images| images.last()).map(PathBuf::as_path),
                    &image.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default());
                let mut too_long = false;
                if let Some(images) = followed.get_mut(&pid) {
                    images.push(image);
                    too_long = images.len() > 8;
                }
                if too_long {
                    followed.remove(&pid); // a long chain of programs: no longer followed
                }
                if !worth {
                    continue; // one look at its name, and nothing more is read
                }
                if let Some(mut snap) = sensor.snapshot(pid) {
                    if let Some(source) = source {
                        snap.parent = source;
                    }
                    snap.jumped = followed.get(&pid).is_some_and(|images| sensor.jumped(&snap.proc, images));
                    snap.handed = followed.get(&pid).is_some_and(|images| sensor.handed(&snap.proc, images));
                    let sent = match &direct {
                        Some(starts) => starts.send(snap),
                        None => sender.send(snap),
                    };
                    if sent.is_err() {
                        break;
                    }
                }
            }
            unsafe { libc::close(handle) };
        })?;
        Ok(ExecFeed { starts, seen, caught, stopped })
    }

    /// True when the kernel reports program starts but none can be found: inside a container or WSL the feed
    /// gives process numbers from outside, which mean nothing here.
    pub fn blind(&self) -> bool {
        self.seen.load(Ordering::Relaxed) >= 20 && self.caught.load(Ordering::Relaxed) == 0
    }

    /// (program starts the kernel reported, how many of them could be found here).
    pub fn counts(&self) -> (u64, u64) {
        (self.seen.load(Ordering::Relaxed), self.caught.load(Ordering::Relaxed))
    }
}

#[cfg(test)]
mod tests {
    use super::web_exec_source;
    use std::path::Path;

    #[test]
    fn a_web_server_replaced_by_a_shell_keeps_its_source() {
        assert_eq!(web_exec_source(Some(Path::new("/home/site/php-fpm8.3")), "dash"), Some("php-fpm8.3".into()));
        assert_eq!(web_exec_source(Some(Path::new("/usr/sbin/nginx")), "python3"), Some("nginx".into()));
        assert_eq!(web_exec_source(Some(Path::new("/usr/bin/bash")), "dash"), None);
        assert_eq!(web_exec_source(Some(Path::new("/usr/sbin/nginx")), "grep"), None);
    }
}

impl Drop for ExecFeed {
    fn drop(&mut self) {
        self.stopped.store(true, Ordering::Relaxed);
    }
}
