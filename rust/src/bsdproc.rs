//! FreeBSD: what is running, asked of the kernel directly (no `/proc` is needed, and none is mounted by default).

#![cfg(target_os = "freebsd")]

fn ask(name: &[libc::c_int]) -> Option<Vec<u8>> {
    let mut size: libc::size_t = 0;
    let found = unsafe { libc::sysctl(name.as_ptr(), name.len() as libc::c_uint, std::ptr::null_mut(), &mut size, std::ptr::null(), 0) };
    if found != 0 || size == 0 || size > 64 * 1024 * 1024 {
        return None;
    }
    // More may have started between the two questions: room for a quarter more.
    let mut data = vec![0u8; size + size / 4 + 4096];
    let mut size: libc::size_t = data.len();
    if unsafe { libc::sysctl(name.as_ptr(), name.len() as libc::c_uint, data.as_mut_ptr() as *mut libc::c_void, &mut size, std::ptr::null(), 0) } != 0 {
        return None;
    }
    data.truncate(size);
    Some(data)
}

fn words(raw: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = raw.iter().take_while(|byte| **byte != 0).map(|byte| *byte as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The records the kernel keeps of these processes, each (process, its parent, the short name the kernel has).
fn records(name: &[libc::c_int]) -> Vec<(u32, u32, String)> {
    let Some(data) = ask(name) else { return Vec::new() };
    let whole = std::mem::size_of::<libc::kinfo_proc>();
    let mut found = Vec::new();
    let mut at = 0;
    while at + whole <= data.len() {
        let record: libc::kinfo_proc = unsafe { std::ptr::read_unaligned(data[at..].as_ptr() as *const libc::kinfo_proc) };
        let step = record.ki_structsize as usize;
        if step < 16 || record.ki_pid <= 0 {
            break;
        }
        found.push((record.ki_pid as u32, record.ki_ppid.max(0) as u32, words(&record.ki_comm)));
        at += step;
    }
    found
}

/// Every running process: (process, its parent, the short name the kernel has for it).
pub fn table() -> Vec<(u32, u32, String)> {
    records(&[libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PROC, 0])
}

/// One process: (its parent, the short name the kernel has for it).
pub fn one(pid: u32) -> Option<(u32, String)> {
    records(&[libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PID, pid as libc::c_int]).into_iter().next().map(|(_, parent, name)| (parent, name))
}

/// The program file a process runs. Empty for the kernel's own.
pub fn path_of(pid: u32) -> String {
    ask(&[libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_PATHNAME, pid as libc::c_int])
        .map(|data| String::from_utf8_lossy(data.split(|byte| *byte == 0).next().unwrap_or(&[])).into_owned()).unwrap_or_default()
}

/// The command line a process was started with, its words joined by spaces.
pub fn line_of(pid: u32) -> String {
    ask(&[libc::CTL_KERN, libc::KERN_PROC, libc::KERN_PROC_ARGS, pid as libc::c_int])
        .map(|data| data.split(|byte| *byte == 0).filter(|part| !part.is_empty()).map(|part| String::from_utf8_lossy(part).into_owned()).collect::<Vec<_>>().join(" ").chars().take(4096).collect())
        .unwrap_or_default()
}
