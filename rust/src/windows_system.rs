//! Locate trusted Windows utilities without consulting the caller's PATH or working directory.

use std::ffi::OsString;
use std::io;
use std::os::windows::ffi::OsStringExt;
use std::path::PathBuf;
use windows_sys::Win32::System::SystemInformation::GetSystemDirectoryW;

fn system_directory() -> io::Result<PathBuf> {
    let mut size = 260usize;
    loop {
        let mut buffer = vec![0u16; size];
        let written = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
        if written == 0 {
            return Err(io::Error::last_os_error());
        }
        if written < size {
            let path = PathBuf::from(OsString::from_wide(&buffer[..written]));
            if path.is_absolute() {
                return Ok(path);
            }
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Windows system directory is not absolute"));
        }
        size = written.saturating_add(1);
        if size > 32768 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "Windows system directory is too long"));
        }
    }
}

pub fn executable(name: &str) -> io::Result<PathBuf> {
    let relative = match name {
        "powershell.exe" => "WindowsPowerShell\\v1.0\\powershell.exe",
        "netsh" | "netsh.exe" => "netsh.exe",
        "route.exe" => "route.exe",
        "bcdedit.exe" => "bcdedit.exe",
        "schtasks.exe" => "schtasks.exe",
        "cmd.exe" => "cmd.exe",
        "ping.exe" => "ping.exe",
        _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "unknown Windows system tool")),
    };
    Ok(system_directory()?.join(relative))
}

/// The system's command processor, given one line to run. The line goes to it exactly as written: quoted the way
/// other programs take their arguments, it would not recognise a quoted program path at all.
pub fn command_line(script: &str) -> io::Result<std::process::Command> {
    use std::os::windows::process::CommandExt;
    let mut command = std::process::Command::new(executable("cmd.exe")?);
    command.args(["/d", "/s", "/c"]).raw_arg(format!("\"{script}\""));
    Ok(command)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn system_tools_ignore_the_caller_path() -> io::Result<()> {
        for name in ["cmd.exe", "schtasks.exe", "powershell.exe", "netsh", "route.exe", "bcdedit.exe"] {
            let path = executable(name)?;
            assert!(path.is_file(), "{}", path.display());
            assert!(path.is_absolute());
        }
        assert!(executable("unknown.exe").is_err());
        Ok(())
    }

    #[test]
    fn delayed_restart_command_uses_absolute_tools() -> io::Result<()> {
        // The second command runs only if the first, a quoted path, was found and succeeded.
        let ping = executable("ping.exe")?;
        let script = format!("\"{}\" -n 1 127.0.0.1 >nul && echo garrett-ready", ping.display());
        let output = command_line(&script)?.output()?;
        assert!(output.status.success());
        assert!(String::from_utf8_lossy(&output.stdout).contains("garrett-ready"));
        Ok(())
    }

    #[test]
    fn fixed_powershell_query_uses_the_system_copy() {
        let said = crate::tool::run(&["powershell.exe", "-NoProfile", "-NonInteractive",
            "-Command", "Write-Output garrett-ready"], None, std::time::Duration::from_secs(10));
        assert_eq!(said.as_deref(), Some("garrett-ready"));
    }
}
