//! Darwin sockaddr_un paths are limited to 104 bytes. TMPDIR is often already
//! 66 bytes: use a short system temporary root, with atomic mode-0700 mkdir.
use std::{os::unix::fs::DirBuilderExt, path::PathBuf};

pub(super) fn create() -> super::Result<PathBuf> {
    for _ in 0..8 {
        let directory = PathBuf::from("/tmp").join(format!("nr-{}", uuid::Uuid::new_v4().simple()));
        match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => return Ok(directory),
            // mkdir rejects existing files, directories and symlinks. Never reuse.
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        }
    }
    Err("could not allocate private socket directory".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    #[test]
    fn long_tmpdir_does_not_limit_claude_or_codex_socket_paths() {
        // A separate process avoids changing other concurrently running tests' env.
        const CHILD: &str = "NEURA_SOCKET_DIR_TEST_CHILD";
        if std::env::var_os(CHILD).is_none() {
            let status = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["providers::socket_dir::tests::long_tmpdir_does_not_limit_claude_or_codex_socket_paths", "--exact"])
                .env(CHILD, "1").env("TMPDIR", format!("/tmp/{}", "long".repeat(60)))
                .status().unwrap();
            assert!(status.success());
            return;
        }
        assert!(std::env::temp_dir().as_os_str().len() > 104);
        for basename in ["activity.sock", "server.sock"] {
            let directory = create().unwrap();
            let metadata = std::fs::symlink_metadata(&directory).unwrap();
            assert!(!metadata.file_type().is_symlink());
            assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
            assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
            let socket = directory.join(basename);
            assert!(socket.as_os_str().len() < 104);
            let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
            drop(listener);
            std::fs::remove_dir_all(directory).unwrap();
        }
    }
}
