//! Keep saved device credentials private even when the state directory predates this version.
//! Use file handles so the security check and DACL change refer to the same object.

use std::ffi::c_void;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::MetadataExt;
use std::path::Path;
use std::ptr::{null, null_mut};

use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, INVALID_HANDLE_VALUE};
use windows_sys::Win32::Security::Authorization::{
    ConvertSidToStringSidW, ConvertStringSidToSidW,
    ConvertStringSecurityDescriptorToSecurityDescriptorW, GetSecurityInfo, SetSecurityInfo,
    SDDL_REVISION_1, SE_FILE_OBJECT,
};
use windows_sys::Win32::Security::{
    GetSecurityDescriptorDacl, GetTokenInformation, TokenUser, DACL_SECURITY_INFORMATION,
    OWNER_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION, PSID, TOKEN_ELEVATION,
    TOKEN_QUERY, TOKEN_USER, TokenElevation,
};
use windows_sys::Win32::Storage::FileSystem::{
    CreateFileW, GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION, FILE_ATTRIBUTE_DIRECTORY,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
    FILE_READ_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING, READ_CONTROL,
    WRITE_DAC, WRITE_OWNER,
};
use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

struct LocalMemory(*mut c_void);

impl Drop for LocalMemory {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { LocalFree(self.0) };
        }
    }
}

fn wide(value: &std::ffi::OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

fn sid_string(sid: PSID) -> io::Result<String> {
    if sid.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "state owner has no SID",
        ));
    }
    let mut raw = null_mut();
    if unsafe { ConvertSidToStringSidW(sid, &mut raw) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let owned = LocalMemory(raw.cast());
    let len = (0..256)
        .find(|&index| unsafe { *raw.add(index) } == 0)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "state owner SID is too long"))?;
    let text = unsafe { std::slice::from_raw_parts(raw, len) };
    let result = String::from_utf16(text)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "state owner SID is invalid"));
    drop(owned);
    result
}

struct Identity {
    sid: String,
    elevated: bool,
}

fn current_identity() -> io::Result<Identity> {
    let mut raw = null_mut();
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw) } == 0 {
        return Err(io::Error::last_os_error());
    }
    let token = Handle(raw);
    let mut needed = 0u32;
    unsafe { GetTokenInformation(token.0, TokenUser, null_mut(), 0, &mut needed) };
    if needed == 0 || needed > 65_536 {
        return Err(io::Error::last_os_error());
    }
    // TOKEN_USER contains a pointer. A usize allocation keeps the buffer aligned.
    let words = (needed as usize).div_ceil(std::mem::size_of::<usize>());
    let mut buffer = vec![0usize; words];
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    if (needed as usize) < std::mem::size_of::<TOKEN_USER>() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "user token is incomplete"));
    }
    let user = unsafe { &*(buffer.as_ptr().cast::<TOKEN_USER>()) };
    let sid = sid_string(user.User.Sid)?;
    let mut elevation = TOKEN_ELEVATION::default();
    if unsafe { GetTokenInformation(token.0, TokenElevation,
        (&mut elevation as *mut TOKEN_ELEVATION).cast(),
        std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut needed) } == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(Identity { sid, elevated: elevation.TokenIsElevated != 0 })
}

fn open(path: &Path) -> io::Result<(Handle, bool)> {
    let name = wide(path.as_os_str());
    let raw = unsafe {
        CreateFileW(
            name.as_ptr(),
            FILE_READ_ATTRIBUTES | READ_CONTROL | WRITE_DAC | WRITE_OWNER,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null(),
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
            null_mut(),
        )
    };
    if raw == INVALID_HANDLE_VALUE {
        return Err(io::Error::last_os_error());
    }
    let handle = Handle(raw);
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(handle.0, &mut info) } == 0 {
        return Err(io::Error::last_os_error());
    }
    if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("state path is a reparse point: {}", path.display()),
        ));
    }
    Ok((
        handle,
        info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0,
    ))
}

fn protect(path: &Path, identity: &Identity) -> io::Result<()> {
    let (handle, directory) = open(path)?;
    let mut owner = null_mut();
    let mut old_descriptor = null_mut();
    let status = unsafe {
        GetSecurityInfo(
            handle.0,
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            null_mut(),
            null_mut(),
            null_mut(),
            &mut old_descriptor,
        )
    };
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    let old_descriptor = LocalMemory(old_descriptor);
    let owner = sid_string(owner)?;
    if owner != identity.sid && owner != "S-1-5-18" && owner != "S-1-5-32-544" {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("state path has an untrusted owner: {}", path.display()),
        ));
    }

    let inherit = if directory { "OICI" } else { "" };
    // An elevated account's user SID is also present in its unelevated token.
    // Move its files to Administrators ownership so UAC still protects them.
    let personal_ace = if identity.elevated || identity.sid == "S-1-5-18" {
        String::new()
    } else {
        format!("(A;{inherit};FA;;;{})", identity.sid)
    };
    let sddl = format!("D:P(A;{inherit};FA;;;SY)(A;{inherit};FA;;;BA){personal_ace}");
    let mut new_descriptor = null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            wide(sddl.as_ref()).as_ptr(),
            SDDL_REVISION_1,
            &mut new_descriptor,
            null_mut(),
        )
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    let new_descriptor = LocalMemory(new_descriptor);
    let mut present = 0;
    let mut defaulted = 0;
    let mut dacl = null_mut();
    if unsafe {
        GetSecurityDescriptorDacl(new_descriptor.0, &mut present, &mut dacl, &mut defaulted)
    } == 0
    {
        return Err(io::Error::last_os_error());
    }
    if present == 0 || dacl.is_null() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "private state ACL has no DACL",
        ));
    }
    let change_owner = identity.elevated && identity.sid != "S-1-5-18"
        && owner != "S-1-5-18" && owner != "S-1-5-32-544";
    let new_owner = if change_owner {
        let mut raw = null_mut();
        if unsafe { ConvertStringSidToSidW(wide("S-1-5-32-544".as_ref()).as_ptr(), &mut raw) } == 0 {
            return Err(io::Error::last_os_error());
        }
        Some(LocalMemory(raw))
    } else {
        None
    };
    let owner_sid = new_owner.as_ref().map_or(null_mut(), |memory| memory.0);
    let security_info = DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION
        | if change_owner { OWNER_SECURITY_INFORMATION } else { 0 };
    let status = unsafe { SetSecurityInfo(handle.0, SE_FILE_OBJECT, security_info,
        owner_sid, null_mut(), dacl, null()) };
    drop(old_descriptor);
    if status != 0 {
        return Err(io::Error::from_raw_os_error(status as i32));
    }
    Ok(())
}

pub fn check_path(path: &Path) -> io::Result<()> {
    let absolute = std::path::absolute(path)?;
    for ancestor in absolute.ancestors() {
        let metadata = match std::fs::symlink_metadata(ancestor) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("state path crosses a reparse point: {}", ancestor.display()),
            ));
        }
    }
    Ok(())
}

pub fn protect_path(path: &Path) -> io::Result<()> {
    check_path(path)?;
    protect(path, &current_identity()?)
}

pub fn protect_tree(root: &Path) -> io::Result<()> {
    check_path(root)?;
    let identity = current_identity()?;
    protect(root, &identity)?;
    let mut pending = vec![(root.to_path_buf(), 0usize)];
    let mut count = 0usize;
    while let Some((directory, depth)) = pending.pop() {
        for entry in std::fs::read_dir(&directory)? {
            let entry = entry?;
            count += 1;
            if count > 8192 || depth >= 32 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "state tree exceeds ACL audit limit",
                ));
            }
            let path = entry.path();
            protect(&path, &identity)?;
            if entry.file_type()?.is_dir() {
                pending.push((path, depth + 1));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::Security::{
        AclSizeInformation, GetAclInformation, GetSecurityDescriptorControl, ACL_SIZE_INFORMATION,
        SE_DACL_PROTECTED,
    };

    fn acl_shape(path: &Path) -> io::Result<(bool, u32)> {
        let (handle, _) = open(path)?;
        let mut dacl = null_mut();
        let mut descriptor = null_mut();
        let status = unsafe {
            GetSecurityInfo(
                handle.0,
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION,
                null_mut(),
                null_mut(),
                &mut dacl,
                null_mut(),
                &mut descriptor,
            )
        };
        if status != 0 {
            return Err(io::Error::from_raw_os_error(status as i32));
        }
        let descriptor = LocalMemory(descriptor);
        let mut control = 0u16;
        let mut revision = 0u32;
        if unsafe { GetSecurityDescriptorControl(descriptor.0, &mut control, &mut revision) } == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut size = ACL_SIZE_INFORMATION::default();
        if unsafe {
            GetAclInformation(
                dacl,
                (&mut size as *mut ACL_SIZE_INFORMATION).cast(),
                std::mem::size_of::<ACL_SIZE_INFORMATION>() as u32,
                AclSizeInformation,
            )
        } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok((control & SE_DACL_PROTECTED != 0, size.AceCount))
    }

    #[test]
    fn protects_existing_state_files() -> io::Result<()> {
        let name = format!(
            "garrett-acl-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let root = std::env::temp_dir().join(name);
        std::fs::create_dir(&root)?;
        let nested = root.join("nested");
        std::fs::create_dir(&nested)?;
        let credential = nested.join("agent.json");
        std::fs::write(&credential, "dummy")?;
        protect_tree(&root)?;
        let expected = if current_identity()?.elevated { 2 } else { 3 };
        for path in [&root, &nested, &credential] {
            assert_eq!(acl_shape(path)?, (true, expected), "{}", path.display());
        }
        std::fs::remove_dir_all(&root)?;
        Ok(())
    }

    #[test]
    fn state_save_and_load_keep_credential_private() -> io::Result<()> {
        let name = format!(
            "garrett-state-acl-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let root = std::env::temp_dir().join(name);
        let state = crate::agent::State::new(Some(root.to_str().unwrap()));
        assert!(state.load().unwrap().is_none());
        let saved =
            serde_json::json!({"server":"https://example.com","token":"a".repeat(64),"pin":""});
        state.save(&saved)?;
        assert_eq!(state.load().unwrap(), Some(saved));
        let expected = if current_identity()?.elevated { 2 } else { 3 };
        assert_eq!(acl_shape(&root)?, (true, expected));
        assert_eq!(acl_shape(&root.join("agent.json"))?, (true, expected));
        std::fs::remove_dir_all(&root)?;
        Ok(())
    }
}
