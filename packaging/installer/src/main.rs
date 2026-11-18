//! garrett-installer: one file that installs the Sentinel service, its decision model and the agent.
//!
//! The release build appends a payload to this program (packaging/build-release.py): the service bundle with
//! its installer, the Node.js runtime, the model's files and the agent's bundle. Run, it writes them to a
//! folder of its own under the system's temporary folder, runs the service installer from there (install.sh as
//! root on Linux, garrett-service.ps1 elevated on Windows) with whatever options it was given, and removes the
//! folder again. Nothing is fetched from the network.
//!
//!   sudo ./garrett-sentinels-linux-x86_64 [--port 8443] [--address <name>] [--memory neuron-db] [--model off] [--wizard]
//!   garrett-sentinels-windows.exe install [-Port 8443] [-Address <name>] [-Memory neuron-db] [-Model off] [-Wizard]
//!   ... --remove   or   ... remove        takes everything out again
//!   ... --extract <folder>                only writes the payload's files there, for a look
//!
//! Payload: records of  u32 path length, path (UTF-8, "/" between folders), u32 mode, u64 size, bytes;
//! then a trailer of  u64 offset of the first record, then the 24-byte magic.
use std::env;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::process::{self, Command};

const MAGIC: &[u8; 24] = b"GARRETT-SENTINELS-PAYL01";

fn fail(message: &str) -> ! {
    eprintln!("{}", message);
    process::exit(1);
}

fn read_u32(bytes: &[u8], at: &mut usize) -> u32 {
    let value = u32::from_le_bytes(bytes[*at..*at + 4].try_into().unwrap());
    *at += 4;
    value
}

fn read_u64(bytes: &[u8], at: &mut usize) -> u64 {
    let value = u64::from_le_bytes(bytes[*at..*at + 8].try_into().unwrap());
    *at += 8;
    value
}

/// The payload appended to this program, or None when there is none.
fn payload() -> io::Result<Option<Vec<u8>>> {
    let own = env::current_exe()?;
    let mut file = File::open(&own)?;
    let length = file.metadata()?.len();
    if length < 32 {
        return Ok(None);
    }
    let mut trailer = [0u8; 32];
    file.seek(SeekFrom::Start(length - 32))?;
    file.read_exact(&mut trailer)?;
    if &trailer[8..] != MAGIC {
        return Ok(None);
    }
    let start = u64::from_le_bytes(trailer[..8].try_into().unwrap());
    if start >= length - 32 {
        fail("The installer's payload is damaged.");
    }
    let mut bytes = vec![0u8; (length - 32 - start) as usize];
    file.seek(SeekFrom::Start(start))?;
    file.read_exact(&mut bytes)?;
    Ok(Some(bytes))
}

/// Writes every record of the payload under `into`. Paths stay inside it: no "..", no absolute paths.
fn extract(bytes: &[u8], into: &Path) -> io::Result<()> {
    let mut at = 0;
    while at < bytes.len() {
        let path_length = read_u32(bytes, &mut at) as usize;
        let path = std::str::from_utf8(&bytes[at..at + path_length]).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "a payload path is not UTF-8"))?;
        at += path_length;
        let mode = read_u32(bytes, &mut at);
        let size = read_u64(bytes, &mut at) as usize;
        if path.is_empty() || path.starts_with('/') || path.contains('\\') || path.split('/').any(|part| part.is_empty() || part == "." || part == "..") || path.contains(':') {
            fail("The installer's payload names a file outside its folder.");
        }
        let target = into.join(path.replace('/', std::path::MAIN_SEPARATOR_STR));
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut out = OpenOptions::new().write(true).create(true).truncate(true).open(&target)?;
        out.write_all(&bytes[at..at + size])?;
        at += size;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&target, fs::Permissions::from_mode(mode & 0o777))?;
        }
        #[cfg(not(unix))]
        let _ = mode;
    }
    Ok(())
}

fn temporary_folder() -> io::Result<PathBuf> {
    let folder = env::temp_dir().join(format!("garrett-sentinels-{}", process::id()));
    if folder.exists() {
        fs::remove_dir_all(&folder)?;
    }
    fs::create_dir_all(&folder)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&folder, fs::Permissions::from_mode(0o700))?;
    }
    Ok(folder)
}

#[cfg(unix)]
fn run_installer(folder: &Path, arguments: &[String]) -> io::Result<i32> {
    let root = Command::new("id").arg("-u").output().map(|out| String::from_utf8_lossy(&out.stdout).trim() == "0").unwrap_or(false);
    if !root {
        fail("Run this as root (put sudo before it).");
    }
    let script = folder.join("garrett-service").join("install.sh");
    let status = Command::new("sh").arg(&script).args(arguments).status()?;
    Ok(status.code().unwrap_or(1))
}

#[cfg(windows)]
fn run_installer(folder: &Path, arguments: &[String]) -> io::Result<i32> {
    let script = folder.join("garrett-service").join("garrett-service.ps1");
    let status = Command::new("powershell.exe")
        .args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(&script)
        .args(arguments)
        .status()?;
    Ok(status.code().unwrap_or(1))
}

#[cfg(windows)]
fn elevated() -> bool {
    // "net session" answers only to an administrator.
    Command::new("net.exe").arg("session").output().map(|out| out.status.success()).unwrap_or(false)
}

#[cfg(windows)]
fn relaunch_elevated(arguments: &[String]) -> ! {
    let own = env::current_exe().unwrap_or_else(|_| fail("This program cannot find itself."));
    let quoted: Vec<String> = arguments.iter().map(|argument| format!("'{}'", argument.replace('\'', "''"))).collect();
    let list = if quoted.is_empty() { String::new() } else { format!(" -ArgumentList {}", quoted.join(",")) };
    let command = format!("Start-Process -FilePath '{}'{} -Verb RunAs -Wait", own.display().to_string().replace('\'', "''"), list);
    let status = Command::new("powershell.exe").args(["-NoProfile", "-Command", &command]).status();
    process::exit(match status {
        Ok(status) if status.success() => 0,
        _ => {
            eprintln!("Windows did not allow the installer to run as an administrator.");
            1
        }
    });
}

fn main() {
    let arguments: Vec<String> = env::args().skip(1).collect();
    if arguments.iter().any(|argument| argument == "--version" || argument == "version") {
        println!("garrett-installer {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    let bytes = match payload() {
        Ok(Some(bytes)) => bytes,
        Ok(None) => fail("This program carries no payload. The release build appends the service, the model and the agent to it; see packaging/build-release.py."),
        Err(error) => fail(&format!("The installer could not read itself: {}", error)),
    };
    if arguments.first().map(String::as_str) == Some("--extract") {
        let into = PathBuf::from(arguments.get(1).unwrap_or_else(|| fail("--extract needs a folder to write into.")));
        fs::create_dir_all(&into).and_then(|_| extract(&bytes, &into)).unwrap_or_else(|error| fail(&format!("The payload could not be written: {}", error)));
        println!("The payload was written to {}", into.display());
        return;
    }
    #[cfg(windows)]
    if !elevated() {
        relaunch_elevated(&arguments);
    }
    let folder = temporary_folder().unwrap_or_else(|error| fail(&format!("No temporary folder could be made: {}", error)));
    let code = match extract(&bytes, &folder).and_then(|_| run_installer(&folder, &arguments)) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("The installer could not run: {}", error);
            1
        }
    };
    let _ = fs::remove_dir_all(&folder);
    #[cfg(windows)]
    if arguments.is_empty() {
        // Double-clicked: the window closes when this returns, so let the result be read first.
        print!("Press Enter to close this window.");
        let _ = io::stdout().flush();
        let mut line = String::new();
        let _ = io::stdin().read_line(&mut line);
    }
    process::exit(code);
}
