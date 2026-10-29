use neura_native_core::{
    browser, contracts, diagnostics, error, events, github, mutation, process_tree, providers, pty,
    store, usage, workspace,
};
mod server;
use std::{
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::PathBuf,
};
#[tokio::main]
async fn main() {
    if run().await.is_err() {
        eprintln!("native daemon failed; no credentials or process arguments logged");
        std::process::exit(1);
    }
}
async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let command = std::env::args().nth(1);
    match command.as_deref() {
        Some("provider-host") => {
            let mut args = std::env::args().skip(2);
            let program = args.next().ok_or("missing program")?;
            let code = process_tree::provider_host(program, args.collect()).await?;
            std::process::exit(code);
        }
        Some("mcp") => return providers::mcp::run().await.map_err(Into::into),
        Some("activity-hook") => return providers::claude::activity_hook().map_err(Into::into),
        Some(_) => return Err("unsupported native subcommand".into()),
        None => {}
    }
    let data = std::env::var_os("NEURA_DEV_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join("Library/Application Support/neuraOS/Developer")
        });
    std::fs::create_dir_all(&data)?;
    std::fs::set_permissions(&data, std::fs::Permissions::from_mode(0o700))?;
    let token_file = data.join("daemon-token");
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&token_file)
    {
        Ok(mut file) => {
            let token = format!(
                "{}{}",
                uuid::Uuid::new_v4().simple(),
                uuid::Uuid::new_v4().simple()
            );
            file.write_all(token.as_bytes())?;
            file.sync_all()?;
        }
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    std::fs::set_permissions(&token_file, std::fs::Permissions::from_mode(0o600))?;
    let token = std::fs::read_to_string(&token_file)?.trim().to_owned();
    if token.is_empty() {
        return Err("empty credential".into());
    }
    let port = std::env::var("NEURA_DEV_PORT")
        .unwrap_or("4318".into())
        .parse::<u16>()?;
    let listener = tokio::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    let endpoint = format!("http://127.0.0.1:{}", listener.local_addr()?.port());
    let state = server::AppState::new(data, token, endpoint.clone())
        .await
        .map_err(|e| e.to_string())?;
    eprintln!("native daemon listening {endpoint}");
    let stop = state.clone();
    let shutdown_failed = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let failed = shutdown_failed.clone();
    axum::serve(listener, server::router(state))
        .with_graceful_shutdown(async move {
            let mut term =
                tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                    .expect("signal");
            tokio::select! {_=tokio::signal::ctrl_c()=>{},_=term.recv()=>{}}
            if stop.shutdown().await.is_err() {
                failed.store(true, std::sync::atomic::Ordering::Release);
                eprintln!("native shutdown durability check failed");
            }
        })
        .await?;
    if shutdown_failed.load(std::sync::atomic::Ordering::Acquire) {
        return Err("shutdown incomplete".into());
    }
    Ok(())
}
