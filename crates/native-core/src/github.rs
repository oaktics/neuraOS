//! GitHub integration. Reads coalesce by repository/commit; mutations revalidate
//! the exact head and never retry an uncertain write.
use crate::error::ApiError;
use serde_json::{json, Value};
use std::process::Stdio;
use std::{
    collections::HashMap,
    future::Future,
    pin::Pin,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{io::AsyncReadExt, process::Command, sync::Mutex as AsyncMutex, time::Instant};
type Result<T> = std::result::Result<T, ApiError>;
type Runner = Arc<
    dyn Fn(String, Vec<String>) -> Pin<Box<dyn Future<Output = Result<String>> + Send>>
        + Send
        + Sync,
>;
fn err(c: &str, m: &str, s: u16) -> ApiError {
    ApiError::new(c, m, s)
}
fn malformed() -> ApiError {
    err("github_response", "GitHub の応答を確認できません。", 502)
}
fn text<'a>(v: &'a Value, k: &str) -> &'a str {
    v.get(k).and_then(Value::as_str).unwrap_or("")
}
fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}
fn parse(v: &str) -> Result<Value> {
    serde_json::from_str(v).map_err(|_| malformed())
}
fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|v| v.to_string()).collect()
}
fn repo_valid(s: &str) -> bool {
    let parts: Vec<_> = s.split('/').collect();
    parts.len() == 2
        && parts.iter().all(|s| {
            !s.is_empty()
                && s.bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
        })
}
pub fn github_repository(remote: &str) -> Result<String> {
    let value = remote.trim();
    let raw = [
        "https://github.com/",
        "git@github.com:",
        "ssh://git@github.com/",
    ]
    .iter()
    .find_map(|prefix| value.strip_prefix(prefix))
    .ok_or_else(|| {
        err(
            "github_remote",
            "origin に github.com の HTTPS または SSH リポジトリを設定してください。",
            400,
        )
    })?;
    let raw = raw.trim_end_matches('/');
    let raw = raw.strip_suffix(".git").unwrap_or(raw);
    if !repo_valid(raw) {
        return Err(err(
            "github_remote",
            "GitHub のリポジトリURLを確認してください。",
            400,
        ));
    }
    Ok(raw.into())
}
pub fn pull_request_number(input: &str, repository: &str) -> Result<u64> {
    let input = input.trim();
    let number = input.strip_prefix('#').unwrap_or(input);
    if !number.starts_with('0') && number.bytes().all(|c| c.is_ascii_digit()) {
        if let Ok(n) = number.parse::<u64>() {
            if n > 0 && n <= 9_007_199_254_740_991 {
                return Ok(n);
            }
        }
    }
    if let Ok(u) = url::Url::parse(input) {
        if u.scheme() == "https"
            && u.host_str() == Some("github.com")
            && u.username().is_empty()
            && u.password().is_none()
            && u.port().is_none()
        {
            let parts: Vec<_> = u.path().trim_start_matches('/').split('/').collect();
            if parts.len() >= 4 && parts[2] == "pull" {
                let repo = format!("{}/{}", parts[0], parts[1]);
                if !repo.eq_ignore_ascii_case(repository) {
                    return Err(err(
                        "pr_repository_mismatch",
                        "選択したプロジェクトとPRのリポジトリが異なります。",
                        400,
                    ));
                }
                return pull_request_number(parts[3], repository);
            }
        }
    }
    Err(err(
        "invalid_pr",
        "PR番号（例: #123）またはGitHubのPR URLを入力してください。",
        400,
    ))
}
#[derive(Clone)]
struct Failure {
    code: String,
    message: String,
    status: u16,
}
impl Failure {
    fn from(e: ApiError) -> Self {
        Self {
            code: e.error,
            message: e.message,
            status: e.status,
        }
    }
    fn error(&self) -> ApiError {
        err(&self.code, &self.message, self.status)
    }
}
struct Cached {
    value: Option<std::result::Result<Value, Failure>>,
    expires: Instant,
    version: u64,
    pending: bool,
}
struct Slot {
    state: Mutex<Cached>,
    gate: AsyncMutex<()>,
}
struct PendingRead(Arc<Slot>);
impl Drop for PendingRead {
    fn drop(&mut self) {
        self.0.state.lock().unwrap().pending = false;
    }
}
#[derive(Clone, Default)]
struct Cache {
    entries: Arc<Mutex<HashMap<String, Arc<Slot>>>>,
}
impl Cache {
    fn invalidate(&self, prefix: &str) {
        self.entries
            .lock()
            .unwrap()
            .retain(|k, _| !k.starts_with(prefix));
    }
    async fn read<F, Fut>(&self, key: String, force: bool, fetch: F) -> Result<Value>
    where
        F: FnOnce() -> Fut,
        Fut: Future<Output = Result<Value>>,
    {
        let slot = {
            let mut entries = self.entries.lock().unwrap();
            if entries.len() >= 256 {
                entries.retain(|_, v| {
                    let s = v.state.lock().unwrap();
                    s.pending || s.expires > Instant::now()
                });
            }
            if entries.len() >= 256 {
                let key = entries
                    .iter()
                    .find(|(_, v)| !v.state.lock().unwrap().pending)
                    .map(|(k, _)| k.clone());
                if let Some(k) = key {
                    entries.remove(&k);
                }
            }
            entries
                .entry(key.clone())
                .or_insert_with(|| {
                    Arc::new(Slot {
                        state: Mutex::new(Cached {
                            value: None,
                            expires: Instant::now(),
                            version: 0,
                            pending: false,
                        }),
                        gate: AsyncMutex::new(()),
                    })
                })
                .clone()
        };
        let target = {
            let s = slot.state.lock().unwrap();
            s.version + if force && s.pending { 2 } else { 1 }
        };
        let gate = slot.gate.lock().await;
        let replaced = force
            && !self
                .entries
                .lock()
                .unwrap()
                .get(&key)
                .is_some_and(|current| Arc::ptr_eq(current, &slot));
        if replaced {
            drop(gate);
            return Box::pin(self.read(key, force, fetch)).await;
        }
        {
            let mut s = slot.state.lock().unwrap();
            if let Some(v) = &s.value {
                if s.expires > Instant::now() && (!force || v.is_err() || s.version >= target) {
                    return v.clone().map_err(|e| e.error());
                }
            }
            s.pending = true;
        }
        // Cancellation of a reader releases the async gate; no detached network
        // operation remains. The next reader can recover the slot.
        let _pending = PendingRead(slot.clone());
        let result = fetch().await.map_err(Failure::from);
        let ttl = match &result {
            Ok(v)
                if text(v, "state") == "CLOSED"
                    || text(v, "state") == "MERGED"
                        && v["checks"].as_array().is_some_and(|c| {
                            c.iter().all(|c| {
                                [
                                    "SUCCESS",
                                    "NEUTRAL",
                                    "SKIPPED",
                                    "FAILURE",
                                    "ERROR",
                                    "TIMED_OUT",
                                    "CANCELLED",
                                    "ACTION_REQUIRED",
                                    "STARTUP_FAILURE",
                                    "STALE",
                                ]
                                .contains(&text(c, "state"))
                            })
                        }) =>
            {
                900
            }
            _ => 60,
        };
        {
            let mut s = slot.state.lock().unwrap();
            s.pending = false;
            s.version += 1;
            s.expires = Instant::now() + Duration::from_secs(ttl);
            s.value = Some(result.clone());
        }
        result.map_err(|e| e.error())
    }
}
async fn executable(name: &str) -> Result<std::path::PathBuf> {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::var("HOME").unwrap_or_default();
    let mut paths = vec![
        format!("{home}/.local/bin/{name}"),
        format!("/opt/homebrew/bin/{name}"),
        format!("/usr/local/bin/{name}"),
    ];
    paths.extend(
        std::env::var("PATH")
            .unwrap_or_default()
            .split(':')
            .map(|p| format!("{p}/{name}")),
    );
    for p in paths {
        if let Ok(m) = tokio::fs::metadata(&p).await {
            if m.is_file() && m.permissions().mode() & 0o111 != 0 {
                if let Ok(p) = tokio::fs::canonicalize(p).await {
                    return Ok(p);
                }
            }
        }
    }
    Err(err(
        "github_cli_missing",
        "GitHub CLI がありません。gh auth login まで完了してください。",
        400,
    ))
}
async fn read_capped(reader: impl tokio::io::AsyncRead + Unpin, limit: u64) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    reader
        .take(limit + 1)
        .read_to_end(&mut bytes)
        .await
        .map_err(|_| malformed())?;
    if bytes.len() > limit as usize {
        return Err(err("github_failed", "コマンドの応答が大きすぎます。", 502));
    }
    Ok(bytes)
}
async fn run(cwd: String, args: Vec<String>, is_gh: bool) -> Result<String> {
    let program = if is_gh {
        executable("gh").await?
    } else {
        std::path::PathBuf::from("/usr/bin/git")
    };
    let mut command = Command::new(program);
    command
        .current_dir(cwd)
        .kill_on_drop(true)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if is_gh {
        command.envs([
            ("GH_HOST", "github.com"),
            ("GH_PROMPT_DISABLED", "1"),
            ("GH_PAGER", "cat"),
            ("GH_DEBUG", ""),
            ("NO_COLOR", "1"),
        ]);
    } else {
        command
            .args(["--no-optional-locks", "-c", "core.quotepath=false"])
            .env("GIT_TERMINAL_PROMPT", "0");
    }
    let tree = crate::process_tree::reserve().await.map_err(|_| err("github_failed", "外部処理の所有予約に失敗しました。", 502))?;
    command
        .env(crate::process_tree::OWNER_ENV, tree.token())
        .args(args);
    let mut child = command
        .spawn()
        .map_err(|_| err("github_failed", "コマンドを開始できません。", 502))?;
    let pid = child.id().ok_or_else(malformed)?;
    if tree.attach(pid).await.is_err() {
        let _ = tree.stop().await;
        let _ = child.kill().await;
        return Err(err("github_failed", "外部処理の所有確認に失敗しました。", 502));
    }
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let limit = if is_gh {
        16 * 1024 * 1024
    } else {
        4 * 1024 * 1024
    };
    let result=tokio::time::timeout(Duration::from_secs(if is_gh{60}else{30}),async{
        let (out,diagnostic,status)=tokio::try_join!(read_capped(stdout,limit),read_capped(stderr,limit),async{child.wait().await.map_err(|_|malformed())})?;
        if status.success(){return String::from_utf8(out).map_err(|_|malformed());}
        let message=String::from_utf8_lossy(&diagnostic).to_lowercase();
        let (code,description,status)=if ["auth login","not logged","bad credentials","http 401"].iter().any(|s|message.contains(s)){("github_auth","GitHub にログインできません。gh auth login を実行してください。",401)}
        else if ["http 403","http 429","rate limit"].iter().any(|s|message.contains(s)){("github_forbidden","GitHub の権限または API 利用制限により操作できません。",403)}
        else if message.contains("http 404"){("github_missing","リポジトリまたは PR が見つかりません。",404)}
        else if ["http 405","http 409","http 422"].iter().any(|s|message.contains(s)){("github_rejected","GitHub が操作を受け付けませんでした。",409)}
        else{("github_failed","操作を完了できませんでした。作成・マージの結果が不明な場合は GitHub 上で確認してください。",502)};
        Err(err(if is_gh{code}else{"git_failed"},description,status))
    }).await;
    let cleanup = tree.stop().await;
    if cleanup.is_err() {
        let _ = child.kill().await;
        return Err(err(
            "github_failed",
            "外部処理の終了を確認できません。操作結果を確認してください。",
            502,
        ));
    }
    match result {
        Ok(Ok(v)) => Ok(v),
        Ok(Err(e)) => {
            let _ = child.kill().await;
            Err(e)
        }
        Err(_) => {
            let _ = child.kill().await;
            Err(err(
                "github_failed",
                "操作がタイムアウトしました。結果を確認してから再試行してください。",
                504,
            ))
        }
    }
}
#[derive(Clone)]
pub struct GitHub {
    gh: Runner,
    git: Runner,
    status_cache: Cache,
    detail_cache: Cache,
    checks_cache: Cache,
}
#[derive(Clone, PartialEq)]
struct Context {
    repository: String,
    head: String,
    branch: String,
}
impl GitHub {
    pub fn new() -> Self {
        Self {
            gh: Arc::new(|c, a| Box::pin(run(c, a, true))),
            git: Arc::new(|c, a| Box::pin(run(c, a, false))),
            status_cache: Cache::default(),
            detail_cache: Cache::default(),
            checks_cache: Cache::default(),
        }
    }
    async fn git(&self, root: &str, args: &[&str]) -> Result<String> {
        (self.git)(root.into(), strings(args)).await
    }
    async fn gh(&self, root: &str, args: &[&str]) -> Result<Value> {
        parse(&(self.gh)(root.into(), strings(args)).await?)
    }
    async fn api(&self, root: &str, endpoint: &str, args: &[&str]) -> Result<Value> {
        let mut all = vec!["api", "--hostname", "github.com", endpoint];
        all.extend(args);
        self.gh(root, &all).await
    }
    async fn pages(&self, root: &str, endpoint: &str) -> Result<Vec<Value>> {
        let v = self.api(root, endpoint, &["--paginate", "--slurp"]).await?;
        let mut out = vec![];
        for page in v.as_array().ok_or_else(malformed)? {
            out.extend(page.as_array().ok_or_else(malformed)?.clone());
        }
        Ok(out)
    }
    async fn context(&self, root: &str, detached: bool) -> Result<Context> {
        let repository =
            github_repository(&self.git(root, &["remote", "get-url", "origin"]).await?)?;
        let head = self
            .git(root, &["rev-parse", "--verify", "HEAD"])
            .await?
            .trim()
            .to_owned();
        let branch = self
            .git(root, &["branch", "--show-current"])
            .await?
            .trim()
            .to_owned();
        if branch.is_empty() && !detached {
            return Err(err(
                "github_detached",
                "ブランチをチェックアウトしてから GitHub を利用してください。",
                400,
            ));
        }
        Ok(Context {
            repository,
            head,
            branch,
        })
    }
    async fn repository(&self, root: &str, repo: &str) -> Result<Value> {
        let v = self.api(root, &format!("repos/{repo}"), &[]).await?;
        if !repo_valid(text(&v, "full_name"))
            || !v["default_branch"].is_string()
            || [
                "allow_merge_commit",
                "allow_squash_merge",
                "allow_rebase_merge",
            ]
            .iter()
            .any(|k| !v[k].is_boolean())
        {
            return Err(malformed());
        }
        Ok(v)
    }
    async fn pulls(&self, root: &str, c: &Context) -> Result<Vec<Value>> {
        let head = format!(
            "{}:{}",
            c.repository.split('/').next().unwrap_or(""),
            c.branch
        );
        let query = url::form_urlencoded::Serializer::new(String::new())
            .extend_pairs([
                ("state", "all"),
                ("head", head.as_str()),
                ("sort", "created"),
                ("direction", "desc"),
                ("per_page", "100"),
            ])
            .finish();
        Ok(self
            .pages(root, &format!("repos/{}/pulls?{query}", c.repository))
            .await?
            .into_iter()
            .filter(|p| {
                text(&p["head"], "ref") == c.branch
                    && text(&p["head"]["repo"], "full_name").eq_ignore_ascii_case(&c.repository)
            })
            .collect())
    }
    fn source(c: &Context, source: Option<&Value>) -> Option<Value> {
        source
            .filter(|s| {
                repo_valid(text(s, "repository"))
                    && text(s, "repository").eq_ignore_ascii_case(&c.repository)
                    && s["number"]
                        .as_u64()
                        .is_some_and(|n| n > 0 && n <= 9_007_199_254_740_991)
                    && !text(s, "localBranch").is_empty()
                    && (40..=64).contains(&text(s, "sourceHead").len())
                    && text(s, "sourceHead")
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            })
            .cloned()
    }
    async fn selected(
        &self,
        root: &str,
        c: &Context,
        source: Option<&Value>,
    ) -> Result<Option<(u64, String, bool)>> {
        let pulls = if c.branch.is_empty() {
            vec![]
        } else {
            self.pulls(root, c).await?
        };
        if let Some(p) = pulls
            .iter()
            .find(|p| text(p, "state") == "open")
            .or(pulls.first())
        {
            return Ok(Some((
                p["number"].as_u64().ok_or_else(malformed)?,
                text(p, "state").into(),
                false,
            )));
        }
        Ok(source.map(|s| (s["number"].as_u64().unwrap(), "source".into(), true)))
    }
    async fn detail(&self, root: &str, repo: &str, n: u64) -> Result<Value> {
        let v=self.gh(root,&["pr","view",&n.to_string(),"--repo",&format!("github.com/{repo}"),"--json","number,title,body,url,state,isDraft,headRefName,headRefOid,baseRefName,mergeStateStatus,reviewDecision,headRepository,headRepositoryOwner,statusCheckRollup,author,additions,deletions,changedFiles,files"]).await?;
        if !v.is_object()
            || v["number"].as_u64() != Some(n)
            || !v["isDraft"].is_boolean()
            || [
                "title",
                "body",
                "url",
                "state",
                "headRefName",
                "headRefOid",
                "baseRefName",
                "mergeStateStatus",
            ]
            .iter()
            .any(|k| !v[k].is_string())
        {
            return Err(malformed());
        }
        Ok(v)
    }
    async fn unresolved(&self, root: &str, repo: &str, n: u64) -> Result<usize> {
        let (owner, name) = repo.split_once('/').ok_or_else(malformed)?;
        let query="query($owner:String!,$name:String!,$number:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100,after:$endCursor){nodes{isResolved} pageInfo{hasNextPage endCursor}}}}}";
        let pages = self
            .api(
                root,
                "graphql",
                &[
                    "--paginate",
                    "--slurp",
                    "-f",
                    &format!("query={query}"),
                    "-f",
                    &format!("owner={owner}"),
                    "-f",
                    &format!("name={name}"),
                    "-F",
                    &format!("number={n}"),
                ],
            )
            .await?;
        let pages = pages
            .as_array()
            .filter(|p| !p.is_empty())
            .ok_or_else(malformed)?;
        let mut count = 0;
        for page in pages {
            for node in page
                .pointer("/data/repository/pullRequest/reviewThreads/nodes")
                .and_then(Value::as_array)
                .ok_or_else(malformed)?
            {
                if !node["isResolved"].as_bool().ok_or_else(malformed)? {
                    count += 1;
                }
            }
        }
        Ok(count)
    }
    pub async fn verify_cleanup(&self, root: &str, n: u64, head: &str) -> Result<()> {
        let repo = github_repository(&self.git(root, &["remote", "get-url", "origin"]).await?)?;
        let v = self
            .gh(
                root,
                &[
                    "pr",
                    "view",
                    &n.to_string(),
                    "--repo",
                    &repo,
                    "--json",
                    "state,headRefOid",
                ],
            )
            .await?;
        if text(&v, "state") != "MERGED" || text(&v, "headRefOid") != head {
            return Err(err(
                "workspace_unmerged",
                "現在のHEADと一致するマージ済みPRを確認できません。作業を保持しました。",
                409,
            ));
        }
        Ok(())
    }
    pub async fn pull_requests(&self, root: &str, query: &str) -> Result<Value> {
        let repo = github_repository(&self.git(root, &["remote", "get-url", "origin"]).await?)?;
        let fields = "number,title,state,headRefName";
        let number = query.trim_start_matches('#');
        let direct = (!number.is_empty() && number.bytes().all(|c| c.is_ascii_digit()))
            || query.to_lowercase().starts_with("http://")
            || query.to_lowercase().starts_with("https://");
        let pulls = if direct {
            let n = pull_request_number(query, &repo)?;
            vec![
                self.gh(
                    root,
                    &[
                        "pr",
                        "view",
                        &n.to_string(),
                        "--repo",
                        &format!("github.com/{repo}"),
                        "--json",
                        fields,
                    ],
                )
                .await?,
            ]
        } else {
            let repo = format!("github.com/{repo}");
            let mut args = vec![
                "pr", "list", "--repo", &repo, "--state", "all", "--limit", "50", "--json", fields,
            ];
            if !query.is_empty() {
                args.extend(["--search", query]);
            }
            self.gh(root, &args)
                .await?
                .as_array()
                .ok_or_else(malformed)?
                .clone()
        };
        for p in &pulls {
            validate_source_pull(p)?;
        }
        Ok(json!({"pullRequests":pulls}))
    }
    pub async fn fetch_pull_request(&self, root: &str, input: &str) -> Result<Value> {
        let repo = github_repository(&self.git(root, &["remote", "get-url", "origin"]).await?)?;
        let n = pull_request_number(input, &repo)?;
        validate_source_pull(
            &self
                .gh(
                    root,
                    &[
                        "pr",
                        "view",
                        &n.to_string(),
                        "--repo",
                        &format!("github.com/{repo}"),
                        "--json",
                        "number,title,state,headRefName",
                    ],
                )
                .await?,
        )?;
        let reference = format!("refs/neura/pr-fetch/{}", uuid::Uuid::new_v4());
        let result=async{self.git(root,&["fetch","--no-tags","origin",&format!("+refs/pull/{n}/head:{reference}")]).await?;let commit=self.git(root,&["rev-parse","--verify",&format!("{reference}^{{commit}}")]).await?.trim().to_owned();Ok(json!({"branch":format!("PR #{n}"),"commit":commit,"pullRequestSource":{"repository":repo,"number":n,"sourceHead":commit}}))}.await;
        let _ = self.git(root, &["update-ref", "-d", &reference]).await;
        result
    }
    pub async fn status(&self, root: &str, force: bool, source: Option<&Value>) -> Result<Value> {
        let c = self.context(root, true).await?;
        let source = Self::source(&c, source);
        if c.branch.is_empty() && source.is_none() {
            return Err(err(
                "github_detached",
                "ブランチをチェックアウトしてください。",
                400,
            ));
        }
        let key = json!([c.repository, c.branch, c.head, source]).to_string();
        let result = self
            .status_cache
            .read(key, force, || {
                self.fetch_status(root, &c, source.as_ref(), force)
            })
            .await?;
        if self.context(root, true).await? != c {
            return Err(err(
                "github_stale",
                "ブランチまたはコミットが変更されました。更新してください。",
                409,
            ));
        }
        Ok(result)
    }
    async fn fetch_status(
        &self,
        root: &str,
        c: &Context,
        source: Option<&Value>,
        force: bool,
    ) -> Result<Value> {
        let (repo, selected) = tokio::try_join!(
            self.repository(root, &c.repository),
            self.selected(root, c, source)
        )?;
        let mut methods = vec![];
        for (field, method) in [
            ("allow_squash_merge", "squash"),
            ("allow_merge_commit", "merge"),
            ("allow_rebase_merge", "rebase"),
        ] {
            if repo[field] == true {
                methods.push(method);
            }
        }
        let mut result = json!({"repository":c.repository,"head":c.head,"branch":c.branch,"defaultBranch":repo["default_branch"],"mergeMethods":methods,"fetchedAt":now(),"sourcePullRequest":null,"pullRequest":null});
        if let Some((n, state, is_source)) = selected {
            if is_source {
                result["sourcePullRequest"] = json!({"repository":c.repository,"number":n});
            }
            result["pullRequest"] = self
                .detail_cache
                .read(
                    format!("{}:{n}:{state}:{}", c.repository, c.head),
                    force,
                    || self.fetch_details(root, &c.repository, n),
                )
                .await?;
        }
        Ok(result)
    }
    async fn fetch_details(&self, root: &str, repo: &str, n: u64) -> Result<Value> {
        let issue = format!("repos/{repo}/issues/{n}/comments?per_page=100");
        let reviews_path = format!("repos/{repo}/pulls/{n}/reviews?per_page=100");
        let lines_path = format!("repos/{repo}/pulls/{n}/comments?per_page=100");
        let (mut pr, comments, reviews, lines, unresolved) = tokio::try_join!(
            self.detail(root, repo, n),
            self.pages(root, &issue),
            self.pages(root, &reviews_path),
            self.pages(root, &lines_path),
            self.unresolved(root, repo, n)
        )?;
        let mut out = vec![];
        for (kind, values) in [("comment", comments), ("review", reviews), ("line", lines)] {
            for c in values {
                let id = c["id"].as_u64().ok_or_else(malformed)?;
                if !c["html_url"].is_string() {
                    return Err(malformed());
                }
                let created = c
                    .get("created_at")
                    .filter(|v| v.is_string())
                    .or(c.get("submitted_at").filter(|v| v.is_string()))
                    .cloned()
                    .unwrap_or(json!(""));
                let line = c
                    .get("line")
                    .filter(|v| !v.is_null())
                    .or(c.get("original_line"))
                    .cloned()
                    .unwrap_or(Value::Null);
                out.push(json!({"id":format!("{kind}-{id}"),"kind":kind,"body":c["body"].as_str().unwrap_or(""),"author":c["user"]["login"].as_str().unwrap_or("削除されたユーザー"),"url":c["html_url"],"createdAt":created,"path":c["path"],"line":line,"outdated":kind=="line"&&c.get("line")==Some(&Value::Null),"state":c["state"]}));
            }
        }
        out.sort_by(|a, b| text(a, "createdAt").cmp(text(b, "createdAt")));
        let checks = check_nodes(pr.get("statusCheckRollup").unwrap_or(&Value::Null))?;
        pr["unresolvedThreads"] = json!(unresolved);
        pr["comments"] = json!(out);
        pr["checks"] = json!(checks
            .into_iter()
            .enumerate()
            .map(|(i, mut c)| {
                c["id"] = json!(i.to_string());
                c
            })
            .collect::<Vec<_>>());
        Ok(pr)
    }
    pub async fn checks(&self, root: &str) -> Result<Value> {
        let c = match self.context(root, true).await {
            Ok(c) => c,
            Err(e) => {
                return Ok(
                    json!({"state":if e.error=="github_remote"{"unsupported"}else{"unavailable"},"checks":[],"fetchedAt":now(),"message":e.message}),
                )
            }
        };
        let value=self.checks_cache.read(format!("{}:{}",c.repository,c.head),false,||async{
            let(owner,name)=c.repository.split_once('/').ok_or_else(malformed)?;
            let query="query($owner:String!,$name:String!,$head:String!,$endCursor:String){repository(owner:$owner,name:$name){object(expression:$head){... on Commit{oid statusCheckRollup{contexts(first:100,after:$endCursor){nodes{... on CheckRun{name status conclusion detailsUrl} ... on StatusContext{context state targetUrl}} pageInfo{hasNextPage endCursor}}}}}}}";
            let value=self.api(root,"graphql",&["--paginate","--slurp","-f",&format!("query={query}"),"-f",&format!("owner={owner}"),"-f",&format!("name={name}"),"-f",&format!("head={}",c.head)]).await?;
            let mut result=parse_checks(&value,&c.head)?;result["repository"]=json!(c.repository);result["head"]=json!(c.head);result["fetchedAt"]=json!(now());Ok(result)
        }).await.unwrap_or_else(|e|json!({"state":"unavailable","checks":[],"fetchedAt":now(),"message":e.message}));
        match self.context(root, true).await {
            Ok(current) if current.repository == c.repository && current.head == c.head => {
                Ok(value)
            }
            Ok(_) => Ok(
                json!({"state":"unknown","checks":[],"fetchedAt":now(),"message":"コミットが変わりました。次の更新でCIを確認します。"}),
            ),
            Err(_) => Ok(json!({"state":"unavailable","checks":[],"fetchedAt":now()})),
        }
    }
    async fn target(&self, root: &str, c: &Value) -> Result<Context> {
        let context = self.context(root, false).await?;
        if context.repository != text(c, "repository")
            || context.branch != text(c, "branch")
            || context.head != text(c, "expectedHead")
        {
            return Err(err(
                "github_stale",
                "リポジトリ、ブランチ、またはコミットが変更されています。",
                409,
            ));
        }
        Ok(context)
    }
    fn invalidate(&self, repo: &str) {
        self.status_cache.invalidate(&format!("[{},", json!(repo)));
        self.detail_cache.invalidate(&format!("{repo}:"));
        self.checks_cache.invalidate(&format!("{repo}:"));
    }
    pub async fn mutate(&self, root: &str, c: &Value, source: Option<&Value>) -> Result<Value> {
        self.invalidate(text(c, "repository"));
        let result = self.perform_mutation(root, c, source).await;
        self.invalidate(text(c, "repository"));
        result
    }
    async fn perform_mutation(
        &self,
        root: &str,
        c: &Value,
        source: Option<&Value>,
    ) -> Result<Value> {
        let context = self.target(root, c).await?;
        let repo = &context.repository;
        match text(c, "type") {
            "github.push" => {
                let remote = self
                    .git(root, &["remote", "get-url", "--push", "--all", "origin"])
                    .await?;
                let remotes: Vec<_> = remote.trim().lines().collect();
                if remotes.len() != 1 || github_repository(remotes[0])? != *repo {
                    return Err(err(
                        "github_push_remote",
                        "origin の push 先が表示中のリポジトリと一致しません。",
                        400,
                    ));
                }
                self.git(
                    root,
                    &[
                        "-c",
                        "remote.origin.mirror=false",
                        "push",
                        "--no-follow-tags",
                        remotes[0],
                        &format!("{}:refs/heads/{}", context.head, context.branch),
                    ],
                )
                .await?;
                Ok(json!({"ok":true,"message":"コミットを push しました。"}))
            }
            "github.create" => {
                if self
                    .pulls(root, &context)
                    .await?
                    .iter()
                    .any(|p| text(p, "state") == "open")
                {
                    return Err(err(
                        "github_pr_exists",
                        "このブランチには PR があります。",
                        409,
                    ));
                }
                if text(c, "base") == context.branch {
                    return Err(err(
                        "github_base",
                        "作業ブランチとは異なるマージ先を指定してください。",
                        400,
                    ));
                }

                let encoded: String =
                    url::form_urlencoded::byte_serialize(context.branch.as_bytes()).collect();
                let remote = self
                    .api(root, &format!("repos/{repo}/git/ref/heads/{encoded}"), &[])
                    .await?;
                if text(&remote["object"], "sha") != context.head {
                    return Err(err(
                        "github_push_required",
                        "最新のコミットを push してから PR を作成してください。",
                        409,
                    ));
                }
                self.target(root, c).await?;
                let pr = self
                    .api(
                        root,
                        &format!("repos/{repo}/pulls"),
                        &[
                            "--method",
                            "POST",
                            "-f",
                            &format!("title={}", text(c, "title")),
                            "-f",
                            &format!("body={}", text(c, "body")),
                            "-f",
                            &format!("head={}", context.branch),
                            "-f",
                            &format!("base={}", text(c, "base")),
                            "-F",
                            &format!("draft={}", c["draft"].as_bool().unwrap_or(false)),
                        ],
                    )
                    .await?;
                if !pr["html_url"].is_string() {
                    return Err(malformed());
                }
                Ok(json!({"ok":true,"message":"PR を作成しました。","url":pr["html_url"]}))
            }
            "github.merge" => {
                let n = c["number"]
                    .as_u64()
                    .filter(|n| *n > 0)
                    .ok_or_else(malformed)?;
                let (pr, unresolved, repository) = tokio::try_join!(
                    self.detail(root, repo, n),
                    self.unresolved(root, repo, n),
                    self.repository(root, repo)
                )?;
                let binding = Self::source(&context, source);
                let matches = if binding.is_some() {
                    self.selected(root, &context, binding.as_ref())
                        .await?
                        .is_some_and(|(number, _, _)| number == n)
                } else {
                    text(&pr, "headRefName") == context.branch
                        && format!(
                            "{}/{}",
                            text(&pr["headRepositoryOwner"], "login"),
                            text(&pr["headRepository"], "name")
                        )
                        .eq_ignore_ascii_case(repo)
                };
                if !matches {
                    return Err(err(
                        "github_pr_mismatch",
                        "この作業ブランチの PR ではありません。",
                        409,
                    ));
                }
                if text(&pr, "headRefOid") != text(c, "expectedPRHead")
                    || text(&pr, "headRefOid") != context.head
                {
                    return Err(err(
                        "github_stale",
                        "PR とローカルのコミットが一致しません。",
                        409,
                    ));
                }
                if text(&pr, "state") != "OPEN"
                    || pr["isDraft"] != false
                    || text(&pr, "mergeStateStatus") != "CLEAN"
                    || text(&pr, "reviewDecision") == "CHANGES_REQUESTED"
                    || unresolved > 0
                {
                    return Err(err(
                        "github_merge_blocked",
                        "Draft、CI、レビュー、未解決コメント、競合を確認してください。",
                        409,
                    ));
                }
                let method = text(c, "method");
                let allowed = match method {
                    "merge" => repository["allow_merge_commit"] == true,
                    "squash" => repository["allow_squash_merge"] == true,
                    "rebase" => repository["allow_rebase_merge"] == true,
                    _ => false,
                };
                if !allowed {
                    return Err(err(
                        "github_merge_method",
                        "選択したマージ方式を利用できません。",
                        409,
                    ));
                }
                self.target(root, c).await?;
                let result = self
                    .api(
                        root,
                        &format!("repos/{repo}/pulls/{n}/merge"),
                        &[
                            "--method",
                            "PUT",
                            "-f",
                            &format!("sha={}", text(c, "expectedPRHead")),
                            "-f",
                            &format!("merge_method={method}"),
                        ],
                    )
                    .await?;
                if result["merged"] != true {
                    return Err(err(
                        "github_merge_blocked",
                        "GitHub がマージを完了しませんでした。",
                        409,
                    ));
                }
                Ok(json!({"ok":true,"message":format!("PR #{n} をマージしました。")}))
            }
            _ => Err(err("invalid_request", "不明な GitHub 操作です。", 400)),
        }
    }
}
fn validate_source_pull(p: &Value) -> Result<()> {
    if !p["number"].as_u64().is_some_and(|n| n > 0)
        || !p["title"].is_string()
        || !p["headRefName"].is_string()
        || !["OPEN", "CLOSED", "MERGED"].contains(&text(p, "state"))
    {
        Err(malformed())
    } else {
        Ok(())
    }
}
fn check_nodes(nodes: &Value) -> Result<Vec<Value>> {
    if nodes.is_null() {
        return Ok(vec![]);
    }
    nodes
        .as_array()
        .ok_or_else(malformed)?
        .iter()
        .map(|c| {
            if !c.is_object() {
                return Err(malformed());
            }
            let name = c["name"]
                .as_str()
                .or(c["context"].as_str())
                .unwrap_or("チェック");
            let state = ["conclusion", "status", "state"]
                .iter()
                .find_map(|k| c[k].as_str().filter(|s| !s.is_empty()))
                .unwrap_or("UNKNOWN");
            let url = c["detailsUrl"]
                .as_str()
                .filter(|s| !s.is_empty())
                .or(c["targetUrl"].as_str().filter(|s| !s.is_empty()));
            Ok(json!({"name":name,"state":state,"url":url}))
        })
        .collect()
}
pub fn summarize_checks(checks: &[Value]) -> &'static str {
    if checks.is_empty() {
        return "none";
    }
    let states: Vec<_> = checks.iter().map(|c| text(c, "state")).collect();
    if states.iter().any(|s| {
        [
            "FAILURE",
            "ERROR",
            "TIMED_OUT",
            "ACTION_REQUIRED",
            "STARTUP_FAILURE",
            "STALE",
        ]
        .contains(s)
    }) {
        "failure"
    } else if states.iter().any(|s| {
        [
            "PENDING",
            "QUEUED",
            "IN_PROGRESS",
            "WAITING",
            "REQUESTED",
            "EXPECTED",
        ]
        .contains(s)
    }) {
        "running"
    } else if states.contains(&"CANCELLED") {
        "cancelled"
    } else if states
        .iter()
        .all(|s| ["SUCCESS", "NEUTRAL", "SKIPPED"].contains(s))
    {
        "success"
    } else {
        "unknown"
    }
}
pub fn parse_checks(value: &Value, head: &str) -> Result<Value> {
    let pages = value
        .as_array()
        .filter(|p| !p.is_empty())
        .ok_or_else(malformed)?;
    let mut checks = vec![];
    let mut missing = 0;
    for page in pages {
        let repo = page
            .pointer("/data/repository")
            .filter(|v| v.is_object())
            .ok_or_else(|| err("github_missing", "GitHub リポジトリを取得できません。", 404))?;
        let commit = repo.get("object").ok_or_else(malformed)?;
        if commit.is_null() {
            missing += 1;
            continue;
        }
        if text(commit, "oid") != head {
            return Err(err("github_head", "CI のコミットを確認できません。", 409));
        }
        if !commit["statusCheckRollup"].is_null() {
            checks.extend(check_nodes(
                commit
                    .pointer("/statusCheckRollup/contexts/nodes")
                    .ok_or_else(malformed)?,
            )?);
        }
    }
    if missing == pages.len() {
        return Ok(json!({"state":"unpublished","checks":[]}));
    }
    if missing > 0 {
        return Err(err("github_head", "CI のコミットを確認できません。", 409));
    }
    Ok(json!({"state":summarize_checks(&checks),"checks":checks}))
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    #[test]
    fn repository_and_pr_inputs() {
        for value in [
            "https://github.com/oaktics/neuraOS.git",
            "git@github.com:oaktics/neuraOS.git",
            "ssh://git@github.com/oaktics/neuraOS.git",
        ] {
            assert_eq!(github_repository(value).unwrap(), "oaktics/neuraOS");
        }
        for value in [
            "https://evil.test/oaktics/neuraOS",
            "https://github.com/user/repo/extra",
            "https://user:pass@github.com/user/repo",
        ] {
            assert!(github_repository(value).is_err());
        }
        assert_eq!(pull_request_number("#123", "oaktics/neuraOS").unwrap(), 123);
        assert_eq!(
            pull_request_number(
                "https://github.com/oaktics/neuraOS/pull/123/files",
                "oaktics/neuraOS"
            )
            .unwrap(),
            123
        );
        assert_eq!(
            pull_request_number("https://github.com/other/repo/pull/123", "oaktics/neuraOS")
                .unwrap_err()
                .error,
            "pr_repository_mismatch"
        );
        for value in ["0", "01", "9007199254740992", "#x"] {
            assert!(pull_request_number(value, "oaktics/neuraOS").is_err());
        }
    }
    #[test]
    fn check_rollup_validates_every_page_and_head() {
        let page = |oid: &str, nodes: Value| json!({"data":{"repository":{"object":{"oid":oid,"statusCheckRollup":{"contexts":{"nodes":nodes}}}}}});
        let value = json!([
            page(
                "head",
                json!([{"name":"test","status":"COMPLETED","conclusion":"SUCCESS"}])
            ),
            page("head", json!([{"context":"build","state":"PENDING"}]))
        ]);
        assert_eq!(parse_checks(&value, "head").unwrap()["state"], "running");
        assert_eq!(
            parse_checks(&value, "other").unwrap_err().error,
            "github_head"
        );
        assert!(parse_checks(&json!([]), "head").is_err());
        assert_eq!(
            parse_checks(&json!([{"data":{"repository":{"object":null}}}]), "head").unwrap()
                ["state"],
            "unpublished"
        );
        assert_eq!(
            summarize_checks(&[json!({"state":"FAILURE"}), json!({"state":"PENDING"})]),
            "failure"
        );
    }
    #[tokio::test]
    async fn cache_coalesces_and_cools_down_failures() {
        let cache = Cache::default();
        let calls = AtomicUsize::new(0);
        let read = || {
            cache.read("repo:head".into(), false, || async {
                calls.fetch_add(1, Ordering::SeqCst);
                tokio::task::yield_now().await;
                Ok(json!({"state":"OPEN"}))
            })
        };
        let (a, b) = tokio::join!(read(), read());
        assert_eq!(a.unwrap(), b.unwrap());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        cache.invalidate("repo:");
        let _ = cache
            .read("repo:head".into(), false, || async {
                calls.fetch_add(1, Ordering::SeqCst);
                Err(err("test", "failed", 502))
            })
            .await;
        assert!(cache
            .read("repo:head".into(), true, || async {
                panic!("failure cooldown bypassed")
            })
            .await
            .is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
    #[tokio::test]
    async fn forced_refresh_joins_one_followup_after_inflight_read() {
        let cache = Cache::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let hold = Arc::new(tokio::sync::Notify::new());
        let c = cache.clone();
        let n = calls.clone();
        let h = hold.clone();
        let first = tokio::spawn(async move {
            c.read("key".into(), false, || async {
                n.fetch_add(1, Ordering::SeqCst);
                h.notified().await;
                Ok(json!({"value":1}))
            })
            .await
        });
        tokio::task::yield_now().await;
        let spawn = || {
            let c = cache.clone();
            let n = calls.clone();
            tokio::spawn(async move {
                c.read("key".into(), true, || async {
                    n.fetch_add(1, Ordering::SeqCst);
                    Ok(json!({"value":2}))
                })
                .await
            })
        };
        let a = spawn();
        let b = spawn();
        tokio::task::yield_now().await;
        hold.notify_one();
        assert_eq!(first.await.unwrap().unwrap()["value"], 1);
        assert_eq!(a.await.unwrap().unwrap()["value"], 2);
        assert_eq!(b.await.unwrap().unwrap()["value"], 2);
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }
    fn mocked(pr: Value, threads: Value) -> (GitHub, Arc<AtomicUsize>) {
        let mut g = GitHub::new();
        let writes = Arc::new(AtomicUsize::new(0));
        let count = writes.clone();
        g.git = Arc::new(|_, args| {
            Box::pin(async move {
                Ok(match args[0].as_str() {
                    "remote" => "https://github.com/oaktics/neuraOS.git",
                    "rev-parse" => "head",
                    "branch" => "feature",
                    _ => "",
                }
                .into())
            })
        });
        g.gh = Arc::new(move |_, args| {
            let pr = pr.clone();
            let threads = threads.clone();
            let count = count.clone();
            Box::pin(async move {
                if args.iter().any(|a| a == "PUT" || a == "POST") {
                    count.fetch_add(1, Ordering::SeqCst);
                    return Ok(json!({"merged":true}).to_string());
                }
                if args.first().is_some_and(|v| v == "pr") {
                    return Ok(pr.to_string());
                }
                if args.iter().any(|a| a == "graphql") {
                    return Ok(threads.to_string());
                }
                Ok(json!({"full_name":"oaktics/neuraOS","default_branch":"main","allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}).to_string())
            })
        });
        (g, writes)
    }
    fn valid_pr() -> Value {
        json!({"number":1,"title":"title","body":"body","url":"https://github.com/oaktics/neuraOS/pull/1","state":"OPEN","isDraft":false,"headRefName":"feature","headRefOid":"head","baseRefName":"main","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","headRepository":{"name":"neuraOS"},"headRepositoryOwner":{"login":"oaktics"},"statusCheckRollup":[]})
    }
    fn threads(resolved: bool) -> Value {
        json!([{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":resolved}]}}}}}])
    }
    fn merge() -> Value {
        json!({"type":"github.merge","repository":"oaktics/neuraOS","branch":"feature","expectedHead":"head","expectedPRHead":"head","number":1,"method":"squash"})
    }
    #[tokio::test]
    async fn merge_rejects_stale_unresolved_draft_and_malformed_evidence() {
        for (field, value, code) in [
            ("headRefOid", json!("other"), "github_stale"),
            ("isDraft", json!(true), "github_merge_blocked"),
            ("mergeStateStatus", json!("BLOCKED"), "github_merge_blocked"),
            ("headRefName", json!("other"), "github_pr_mismatch"),
        ] {
            let mut pr = valid_pr();
            pr[field] = value;
            let (g, writes) = mocked(pr, threads(true));
            assert_eq!(
                g.mutate("/tmp", &merge(), None).await.unwrap_err().error,
                code
            );
            assert_eq!(writes.load(Ordering::SeqCst), 0);
        }
        let (g, writes) = mocked(valid_pr(), threads(false));
        assert_eq!(
            g.mutate("/tmp", &merge(), None).await.unwrap_err().error,
            "github_merge_blocked"
        );
        assert_eq!(writes.load(Ordering::SeqCst), 0);
        let (g, writes) = mocked(valid_pr(), json!([]));
        assert!(g.mutate("/tmp", &merge(), None).await.is_err());
        assert_eq!(writes.load(Ordering::SeqCst), 0);
        let (g, writes) = mocked(valid_pr(), threads(true));
        assert_eq!(g.mutate("/tmp", &merge(), None).await.unwrap()["ok"], true);
        assert_eq!(writes.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn cleanup_requires_exact_merged_head() {
        let (g, _) = mocked(
            json!({"state":"MERGED","headRefOid":"exact"}),
            threads(true),
        );
        assert!(g.verify_cleanup("/tmp", 1, "other").await.is_err());
        assert!(g.verify_cleanup("/tmp", 1, "exact").await.is_ok());
    }
    #[tokio::test]
    async fn forced_read_after_invalidation_updates_current_slot() {
        let cache = Cache::default();
        let hold = Arc::new(tokio::sync::Notify::new());
        let c = cache.clone();
        let h = hold.clone();
        let initial = tokio::spawn(async move {
            c.read("key".into(), false, || async {
                h.notified().await;
                Ok(json!(1))
            })
            .await
        });
        tokio::task::yield_now().await;
        let c = cache.clone();
        let forced =
            tokio::spawn(
                async move { c.read("key".into(), true, || async { Ok(json!(3)) }).await },
            );
        tokio::task::yield_now().await;
        cache.invalidate("key");
        assert_eq!(
            cache
                .read("key".into(), false, || async { Ok(json!(2)) })
                .await
                .unwrap(),
            json!(2)
        );
        hold.notify_one();
        assert_eq!(initial.await.unwrap().unwrap(), json!(1));
        assert_eq!(forced.await.unwrap().unwrap(), json!(3));
        assert_eq!(
            cache
                .read("key".into(), false, || async {
                    panic!("new cache discarded")
                })
                .await
                .unwrap(),
            json!(3)
        );
    }
}

#[cfg(test)]
mod output_bound_tests {
    use super::*;
    #[tokio::test]
    async fn oversized_output_fails_without_waiting_for_eof() {
        use tokio::io::AsyncWriteExt;
        let (reader, mut writer) = tokio::io::duplex(64);
        let producer = tokio::spawn(async move {
            writer.write_all(&[b'x'; 33]).await.unwrap();
            std::future::pending::<()>().await;
        });
        let result = tokio::time::timeout(Duration::from_secs(1), read_capped(reader, 32))
            .await
            .unwrap();
        producer.abort();
        assert_eq!(result.unwrap_err().error, "github_failed");
    }
}
