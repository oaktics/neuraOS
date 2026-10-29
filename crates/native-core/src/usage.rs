//! Read-only provider quota queries. Credentials never leave the request path or
//! enter stored state, errors, snapshots, or command-line arguments.
use serde_json::{json, Value};
use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::Command,
    sync::Mutex,
    time::Instant,
};
#[derive(Debug, Clone, Copy)]
pub enum UsageError {
    Unavailable,
    SignedOut,
}
type Result<T> = std::result::Result<T, UsageError>;
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn percent(v: &Value) -> Result<f64> {
    v.as_f64()
        .filter(|n| n.is_finite() && *n >= 0.0)
        .ok_or(UsageError::Unavailable)
}
fn iso_seconds(v: &Value) -> Value {
    v.as_f64()
        .filter(|n| n.is_finite() && *n >= 0.0 && *n <= 8_640_000_000_000.0)
        .and_then(|n| chrono::DateTime::from_timestamp_millis((n * 1000.0) as i64))
        .map(|d| json!(d.to_rfc3339_opts(chrono::SecondsFormat::Millis, true)))
        .unwrap_or(Value::Null)
}
pub fn parse_codex_usage(v: &Value) -> Result<Value> {
    if !v.is_object() {
        return Err(UsageError::Unavailable);
    }
    let preferred = v
        .pointer("/rateLimitsByLimitId/codex")
        .filter(|v| !v.is_null());
    let bucket = preferred.or_else(|| {
        v.get("rateLimits")
            .filter(|b| b["limitId"].is_null() || b["limitId"] == "codex")
    });
    let mut out = vec![];
    if let Some(b) = bucket {
        if !b.is_null() && !b.is_object() {
            return Err(UsageError::Unavailable);
        }
        for (index, key) in ["primary", "secondary"].iter().enumerate() {
            let w = &b[key];
            if w.is_null() {
                continue;
            }
            let used = percent(&w["usedPercent"])?;
            let duration = if w["windowDurationMins"].is_null() {
                None
            } else {
                Some(
                    w["windowDurationMins"]
                        .as_f64()
                        .filter(|n| n.is_finite() && *n > 0.0)
                        .ok_or(UsageError::Unavailable)?,
                )
            };
            if !w["resetsAt"].is_null() {
                percent(&w["resetsAt"])?;
            }
            let label = match duration {
                Some(10080.0) => "週".to_owned(),
                Some(n) if n % 60.0 == 0.0 => format!("{}h", n / 60.0),
                Some(n) => format!("{n}m"),
                None => if index == 0 { "短期" } else { "長期" }.to_owned(),
            };
            out.push(
                json!({"label":label,"usedPercent":used,"resetsAt":iso_seconds(&w["resetsAt"])}),
            );
        }
    }
    Ok(json!(out))
}
pub fn parse_claude_usage(v: &Value) -> Result<Value> {
    if !v.is_object() {
        return Err(UsageError::Unavailable);
    }
    let mut out = vec![];
    for (key, label) in [("five_hour", "5h"), ("seven_day", "週")] {
        let w = &v[key];
        if w.is_null() {
            continue;
        }
        let used = percent(&w["utilization"])?;
        let reset = if w["resets_at"].is_null() {
            Value::Null
        } else {
            let text = w["resets_at"].as_str().ok_or(UsageError::Unavailable)?;
            chrono::DateTime::parse_from_rfc3339(text)
                .ok()
                .map(|d| {
                    json!(d
                        .with_timezone(&chrono::Utc)
                        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
                })
                .unwrap_or(Value::Null)
        };
        out.push(json!({"label":label,"usedPercent":used,"resetsAt":reset}));
    }
    Ok(json!(out))
}
fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}
async fn codex_executable() -> Result<PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let candidates = if let Some(p) = std::env::var_os("NEURA_CODEX_PATH") {
        vec![PathBuf::from(p)]
    } else {
        let mut paths = vec![
            home().join(".local/bin/codex"),
            PathBuf::from("/opt/homebrew/bin/codex"),
            PathBuf::from("/usr/local/bin/codex"),
        ];
        paths.extend(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
                .map(|p| p.join("codex")),
        );
        paths
    };
    for path in candidates {
        if let Ok(m) = tokio::fs::metadata(&path).await {
            if m.is_file() && m.permissions().mode() & 0o111 != 0 {
                if let Ok(p) = tokio::fs::canonicalize(path).await {
                    return Ok(p);
                }
            }
        }
    }
    Err(UsageError::Unavailable)
}
async fn send(writer: &mut tokio::process::ChildStdin, v: Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(&v).map_err(|_| UsageError::Unavailable)?;
    bytes.push(b'\n');
    writer
        .write_all(&bytes)
        .await
        .map_err(|_| UsageError::Unavailable)
}
pub async fn read_codex_usage(program: Option<PathBuf>) -> Result<Value> {
    let program = match program {
        Some(p) => p,
        None => codex_executable().await?,
    };
    let mut command = Command::new(program);
    command
        .process_group(0)
        .args(["app-server", "--listen", "stdio://"])
        .current_dir(home())
        .env_clear()
        .env("HOME", home())
        .env("USER", std::env::var("USER").unwrap_or_default())
        .env("SHELL", "/bin/zsh")
        .env("TERM", "xterm-256color")
        .env(
            "LANG",
            std::env::var("LANG").unwrap_or("en_US.UTF-8".into()),
        )
        .env(
            "PATH",
            format!(
                "{}:/opt/homebrew/bin:/usr/local/bin:{}",
                home().join(".local/bin").display(),
                std::env::var("PATH").unwrap_or("/usr/bin:/bin".into())
            ),
        )
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let tree = crate::process_tree::reserve().await.map_err(|_| UsageError::Unavailable)?;
    command.env(crate::process_tree::OWNER_ENV, tree.token());
    let mut child = command.spawn().map_err(|_| UsageError::Unavailable)?;
    let pid = child.id().ok_or(UsageError::Unavailable)?;
    if tree.attach(pid).await.is_err() {
        let _ = tree.stop().await;
        let _ = child.kill().await;
        return Err(UsageError::Unavailable);
    }
    let mut input = child.stdin.take().ok_or(UsageError::Unavailable)?;
    let output = child.stdout.take().ok_or(UsageError::Unavailable)?;
    let result=tokio::time::timeout(Duration::from_secs(10),async{
        send(&mut input,json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"neuraos_usage","title":"neuraOS usage","version":"0.2.0"}}})).await?;
        let mut reader=BufReader::new(output);let mut initialized=false;
        loop{
            let mut line=vec![];let count=(&mut reader).take(1024*1024+1).read_until(b'\n',&mut line).await.map_err(|_|UsageError::Unavailable)?;
            if count==0||count>1024*1024{return Err(UsageError::Unavailable);}
            let message:Value=serde_json::from_slice(&line).map_err(|_|UsageError::Unavailable)?;
            let id=message["id"].as_u64();if !matches!(id,Some(1|2)){continue;}
            if !message["error"].is_null(){return Err(UsageError::Unavailable);}
            if id==Some(1)&&!initialized{initialized=true;send(&mut input,json!({"method":"initialized"})).await?;send(&mut input,json!({"id":2,"method":"account/rateLimits/read"})).await?;}
            else if id==Some(2)&&initialized{return parse_codex_usage(&message["result"]);}
        }
    }).await.unwrap_or(Err(UsageError::Unavailable));
    drop(input);
    let stopped = tree.stop().await;
    let _ = child.kill().await;
    if stopped.is_err() {
        return Err(UsageError::Unavailable);
    }
    result
}
async fn claude_access_token() -> Result<String> {
    let mut raw = None;
    #[cfg(target_os = "macos")]
    {
        let mut command = Command::new("/usr/bin/security");
        command
            .args([
                "find-generic-password",
                "-s",
                "Claude Code-credentials",
                "-a",
                &std::env::var("USER").unwrap_or_default(),
                "-w",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        if let Ok(mut child) = command.spawn() {
            if let Some(output) = child.stdout.take() {
                let read = tokio::time::timeout(Duration::from_secs(3), async {
                    let mut bytes = vec![];
                    output.take(65537).read_to_end(&mut bytes).await.ok()?;
                    let status = child.wait().await.ok()?;
                    if status.success() && bytes.len() <= 65536 {
                        String::from_utf8(bytes).ok()
                    } else {
                        None
                    }
                })
                .await;
                raw = read.ok().flatten();
                let _ = child.kill().await;
            }
        }
    }
    if raw.is_none() {
        let path = home().join(".claude/.credentials.json");
        if let Ok(file) = tokio::fs::File::open(path).await {
            let mut bytes = vec![];
            if file.take(65537).read_to_end(&mut bytes).await.is_ok() && bytes.len() <= 65536 {
                raw = String::from_utf8(bytes).ok();
            }
        }
    }
    let raw = raw.ok_or(UsageError::SignedOut)?;
    let v: Value = serde_json::from_str(&raw).map_err(|_| UsageError::Unavailable)?;
    let auth = &v["claudeAiOauth"];
    if auth.is_null() {
        return Err(UsageError::SignedOut);
    }
    if let Some(expiry) = auth.get("expiresAt") {
        let expiry = expiry.as_f64().ok_or(UsageError::Unavailable)?;
        if expiry <= chrono::Utc::now().timestamp_millis() as f64 {
            return Err(UsageError::SignedOut);
        }
    }
    auth["accessToken"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .ok_or(UsageError::Unavailable)
}
pub async fn read_claude_usage() -> Result<Value> {
    let token = claude_access_token().await?;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|_| UsageError::Unavailable)?;
    let mut response = client
        .get("https://api.anthropic.com/api/oauth/usage")
        .bearer_auth(token)
        .header("anthropic-beta", "oauth-2025-04-20")
        .send()
        .await
        .map_err(|_| UsageError::Unavailable)?;
    if response.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err(UsageError::SignedOut);
    }
    if !response.status().is_success() {
        return Err(UsageError::Unavailable);
    }
    let mut bytes = vec![];
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| UsageError::Unavailable)?
    {
        if bytes.len() + chunk.len() > 1024 * 1024 {
            return Err(UsageError::Unavailable);
        }
        bytes.extend_from_slice(&chunk);
    }
    parse_claude_usage(&serde_json::from_slice(&bytes).map_err(|_| UsageError::Unavailable)?)
}
struct Cached {
    value: Value,
    expires: Instant,
}
#[derive(Clone)]
pub struct ProviderUsageService {
    cached: Arc<Mutex<Cached>>,
}
impl ProviderUsageService {
    pub fn new() -> Self {
        Self {
            cached: Arc::new(Mutex::new(Cached {
                value: json!([]),
                expires: Instant::now(),
            })),
        }
    }
    pub async fn read(&self) -> Value {
        let mut cache = self.cached.lock().await;
        if cache.expires > Instant::now() {
            return cache.value.clone();
        }
        let (codex, claude) = tokio::join!(read_codex_usage(None), read_claude_usage());
        cache.value = json!([usage_result("codex", codex), usage_result("claude", claude)]);
        cache.expires = Instant::now() + Duration::from_secs(60);
        cache.value.clone()
    }
    pub async fn close(&self) {
        let _guard = self.cached.lock().await;
    }
}
fn usage_result(provider: &str, result: Result<Value>) -> Value {
    let (status, windows) = match result {
        Ok(v) => {
            if v.as_array().is_some_and(|a| !a.is_empty()) {
                ("available", v)
            } else {
                ("unsupported", json!([]))
            }
        }
        Err(UsageError::SignedOut) => ("signed_out", json!([])),
        Err(_) => ("unavailable", json!([])),
    };
    json!({"provider":provider,"status":status,"windows":windows,"checkedAt":now()})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_windows_and_limit_scope() {
        assert_eq!(parse_codex_usage(&json!({"rateLimits":{"primary":null,"secondary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":1793082918}}})).unwrap(),json!([{"label":"週","usedPercent":30.0,"resetsAt":"2026-10-27T06:35:18.000Z"}]));
        assert_eq!(parse_codex_usage(&json!({"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0,"windowDurationMins":300}}},"rateLimits":{"primary":{"usedPercent":99}}})).unwrap()[0]["usedPercent"],0.0);
        assert_eq!(
            parse_codex_usage(
                &json!({"rateLimits":{"limitId":"another","primary":{"usedPercent":42}}})
            )
            .unwrap(),
            json!([])
        );
    }
    #[test]
    fn claude_zero_invalid_and_missing() {
        assert_eq!(
            parse_claude_usage(&json!({"five_hour":{"utilization":0},"seven_day":null})).unwrap(),
            json!([{"label":"5h","usedPercent":0.0,"resetsAt":null}])
        );
        assert_eq!(
            parse_claude_usage(&json!({"seven_day":{"utilization":101,"resets_at":"bad date"}}))
                .unwrap()[0]["resetsAt"],
            Value::Null
        );
        for v in [json!(-1), json!("25")] {
            assert!(parse_claude_usage(&json!({"five_hour":{"utilization":v}})).is_err());
        }
    }
    #[test]
    fn failed_provider_does_not_expose_stale_values() {
        let v = usage_result("claude", Err(UsageError::SignedOut));
        assert_eq!(v["status"], "signed_out");
        assert_eq!(v["windows"], json!([]));
    }
}
