use neura_native_core::{process_tree, usage::read_codex_usage};
use serde_json::json;
use std::os::unix::fs::PermissionsExt;
#[tokio::test]
async fn quota_subprocess_uses_only_account_protocol_and_is_reaped() {
    let dir = std::env::temp_dir().join(format!("neura-quota-native-{}", uuid::Uuid::new_v4()));
    tokio::fs::create_dir(&dir).await.unwrap();
    process_tree::ensure_supervisor(
        std::path::Path::new(env!("CARGO_BIN_EXE_neura-native-core")),
        &dir.join("supervisor.lock"),
    )
    .await
    .unwrap();
    let path = dir.join("codex");
    let script = r##"#!/bin/sh
read -r init
case "$init" in *'"method":"initialize"'*) ;; *) exit 12;; esac
printf '%s\n' '{"id":1,"result":{}}'
read -r ready
case "$ready" in *'"method":"initialized"'*) ;; *) exit 13;; esac
read -r quota
case "$quota" in *'"method":"account/rateLimits/read"'*) ;; *) exit 14;; esac
printf '%s\n' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":7,"windowDurationMins":300}}}}'
read -r unexpected
exit 15
"##;
    tokio::fs::write(&path, script).await.unwrap();
    tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
        .await
        .unwrap();
    let result = read_codex_usage(Some(path.clone())).await.unwrap();
    assert_eq!(
        result,
        json!([{"label":"5h","usedPercent":7.0,"resetsAt":null}])
    );
    tokio::fs::write(&path, "#!/bin/sh\nexit 1\n")
        .await
        .unwrap();
    assert!(read_codex_usage(Some(path)).await.is_err());
    // The runtime closes the helper pipe after this function returns. Keep its
    // lifetime lock inode until then; the isolated test profile is disposable.
}
