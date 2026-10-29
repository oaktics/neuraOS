//! Wire validation kept equivalent to the v1 command contract. Unknown fields
//! are stripped before journaling; invalid input never reaches mutation code.
use crate::error::ApiError;
use serde_json::{json, Map, Value};
use std::collections::HashSet;
fn js_whitespace(c: char) -> bool {
    matches!(c, '\u{0009}'..='\u{000d}' | '\u{0020}' | '\u{00a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{2028}' | '\u{2029}' | '\u{202f}' | '\u{205f}' | '\u{3000}' | '\u{feff}')
}
fn invalid() -> ApiError {
    ApiError::new("invalid_request", "操作の形式が正しくありません。", 400)
}
pub fn valid_uuid(value: &str) -> bool {
    if value == "00000000-0000-0000-0000-000000000000"
        || value == "ffffffff-ffff-ffff-ffff-ffffffffffff"
    {
        return true;
    }
    let b = value.as_bytes();
    b.len() == 36
        && [8, 13, 18, 23].iter().all(|i| b[*i] == b'-')
        && b.iter()
            .enumerate()
            .all(|(i, c)| [8, 13, 18, 23].contains(&i) || c.is_ascii_hexdigit())
        && (b'1'..=b'8').contains(&b[14])
        && b"89abAB".contains(&b[19])
}
#[derive(Clone)]
enum Rule {
    Id,
    Text(usize, usize, bool),
    Enum(&'static [&'static str]),
    Bool,
    Int(i64, i64),
    Hex(usize, usize),
    Repo,
    Ids(Option<usize>, bool),
    Providers,
    RequestId,
    Object,
    Cleanup,
    Optional(Box<Rule>),
    Default(Box<Rule>, Value),
}
use Rule::*;
const PROVIDERS: &[&str] = &["codex", "claude", "shell"];
const CONVERSATION: &[&str] = &["codex", "claude"];
fn optional(r: Rule) -> Rule {
    Optional(Box::new(r))
}
fn default_bool() -> Rule {
    Default(Box::new(Bool), json!(false))
}
fn string(min: usize, max: usize) -> Rule {
    Text(min, max, false)
}
fn trimmed(min: usize, max: usize) -> Rule {
    Text(min, max, true)
}
fn safe_integer(v: &Value) -> Option<i64> {
    v.as_i64()
        .or_else(|| {
            v.as_f64()
                .filter(|n| n.is_finite() && n.fract() == 0.0 && n.abs() <= 9_007_199_254_740_991.0)
                .map(|n| n as i64)
        })
        .filter(|n| n.unsigned_abs() <= 9_007_199_254_740_991)
}
fn validate(rule: &Rule, input: Option<&Value>) -> Result<Option<Value>, ApiError> {
    match rule {
        Optional(inner) => {
            return if input.is_none() {
                Ok(None)
            } else {
                validate(inner, input)
            }
        }
        Default(inner, value) => return validate(inner, Some(input.unwrap_or(value))),
        _ => {}
    }
    let v = input.ok_or_else(invalid)?;
    let value = match rule {
        Id => {
            if !v.as_str().is_some_and(valid_uuid) {
                return Err(invalid());
            }
            v.clone()
        }
        Text(min, max, trim) => {
            let raw = v.as_str().ok_or_else(invalid)?;
            let s = if *trim {
                raw.trim_matches(js_whitespace)
            } else {
                raw
            };
            let length = s.encode_utf16().count();
            if length < *min || length > *max {
                return Err(invalid());
            }
            json!(s)
        }
        Enum(values) => {
            if !v.as_str().is_some_and(|s| values.contains(&s)) {
                return Err(invalid());
            }
            v.clone()
        }
        Bool => {
            if !v.is_boolean() {
                return Err(invalid());
            }
            v.clone()
        }
        Int(min, max) => {
            let n = safe_integer(v)
                .filter(|n| n >= min && n <= max)
                .ok_or_else(invalid)?;
            json!(n)
        }
        Hex(min, max) => {
            let s = v.as_str().ok_or_else(invalid)?;
            if s.len() < *min
                || s.len() > *max
                || !s
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
            {
                return Err(invalid());
            }
            v.clone()
        }
        Repo => {
            let s = v.as_str().ok_or_else(invalid)?;
            let parts: Vec<_> = s.split('/').collect();
            if parts.len() != 2
                || parts.iter().any(|p| {
                    p.is_empty()
                        || !p
                            .bytes()
                            .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
                })
            {
                return Err(invalid());
            }
            v.clone()
        }
        Ids(max, unique) => {
            let array = v.as_array().ok_or_else(invalid)?;
            if max.is_some_and(|m| array.len() > m) {
                return Err(invalid());
            }
            let mut ids = HashSet::new();
            for item in array {
                let id = item
                    .as_str()
                    .filter(|s| valid_uuid(s))
                    .ok_or_else(invalid)?;
                if *unique && !ids.insert(id) {
                    return Err(invalid());
                }
            }
            v.clone()
        }
        Providers => {
            let array = v.as_array().ok_or_else(invalid)?;
            if array.len() > 3 {
                return Err(invalid());
            }
            let mut providers = HashSet::new();
            for item in array {
                let p = item
                    .as_str()
                    .filter(|s| PROVIDERS.contains(s))
                    .ok_or_else(invalid)?;
                if !providers.insert(p) {
                    return Err(invalid());
                }
            }
            v.clone()
        }
        RequestId => {
            if let Some(s) = v.as_str() {
                if s.encode_utf16().count() > 256 {
                    return Err(invalid());
                }
                v.clone()
            } else {
                json!(safe_integer(v).ok_or_else(invalid)?)
            }
        }
        Object => {
            if !v.is_object() {
                return Err(invalid());
            }
            v.clone()
        }
        Cleanup => parse_object(
            v,
            &[
                ("callerWorkspaceId", Id),
                ("expectedHead", Hex(40, 64)),
                ("mergedPR", Int(1, 9_007_199_254_740_991)),
            ],
        )?,
        Optional(_) | Default(_, _) => unreachable!(),
    };
    Ok(Some(value))
}
fn parse_object(v: &Value, schema: &[(&str, Rule)]) -> Result<Value, ApiError> {
    let input = v.as_object().ok_or_else(invalid)?;
    let mut out = Map::new();
    for (key, rule) in schema {
        if let Some(value) = validate(rule, input.get(*key))? {
            out.insert((*key).into(), value);
        }
    }
    Ok(Value::Object(out))
}
pub fn envelope(body: Value) -> Result<(String, Value), ApiError> {
    let b = body.as_object().ok_or_else(invalid)?;
    let id = b
        .get("operationId")
        .and_then(Value::as_str)
        .filter(|s| valid_uuid(s))
        .ok_or_else(invalid)?;
    Ok((
        id.to_owned(),
        command(b.get("command").cloned().ok_or_else(invalid)?)?,
    ))
}
pub fn command(body: Value) -> Result<Value, ApiError> {
    let kind = body
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(invalid)?;
    let fields: Vec<(&str, Rule)> = match kind {
        "project.remove" => vec![("projectId", Id)],
        "project.create" => vec![("name", trimmed(1, 80))],
        "project.attach" => vec![("projectId", Id), ("path", string(1, 4096))],
        "project.add" => vec![("path", string(1, 4096))],
        "project.set-worktree-startup" => vec![("projectId", Id), ("providers", Providers)],
        "project.set-default-providers" => vec![
            ("projectId", Id),
            ("defaultConversationProvider", optional(Enum(CONVERSATION))),
            ("defaultDelegationProvider", optional(Enum(CONVERSATION))),
        ],
        "project.set-worktree-setup" => vec![("projectId", Id), ("script", trimmed(0, 4096))],
        "workspace.setup" | "workspace.sync-default" => vec![("workspaceId", Id)],
        "workspace.create" => vec![
            ("projectId", Id),
            ("name", optional(trimmed(1, 80))),
            ("baseRef", optional(string(1, 200))),
            ("pullRequest", optional(trimmed(1, 500))),
            ("skipStartup", default_bool()),
        ],
        "workspace.delete" => vec![
            ("workspaceId", Id),
            ("discardChanges", default_bool()),
            ("stopTerminals", default_bool()),
            ("cleanup", optional(Cleanup)),
        ],
        "terminal.open" => vec![
            ("workspaceId", Id),
            ("provider", optional(Enum(PROVIDERS))),
            ("resume", default_bool()),
            ("prompt", optional(string(1, 65536))),
            ("resumeId", optional(Id)),
            ("parentTaskId", optional(Id)),
        ],
        "agent.watch" => vec![("agentId", Id), ("taskIds", Ids(None, true))],
        "agent.report" => vec![
            ("agentId", Id),
            ("text", trimmed(1, 16384)),
            ("sourceTerminalId", optional(Id)),
        ],
        "agent.ack" => vec![("agentId", Id), ("reportIds", Ids(Some(32), false))],
        "agent.send" => vec![
            ("agentId", Id),
            ("text", trimmed(1, 65536)),
            (
                "mode",
                Default(Box::new(Enum(&["queue", "steer"])), json!("queue")),
            ),
            ("expectedTurnId", optional(Id)),
        ],
        "agent.interrupt" => vec![("agentId", Id), ("expectedTurnId", Id)],
        "agent.respond" => vec![
            ("agentId", Id),
            ("requestId", RequestId),
            ("result", Object),
        ],
        "terminal.input" => vec![
            ("terminalId", Id),
            ("clientId", Id),
            ("data", string(0, 65536)),
        ],
        "terminal.resize" => vec![
            ("terminalId", Id),
            ("clientId", Id),
            ("cols", Int(20, 400)),
            ("rows", Int(5, 200)),
        ],
        "terminal.stop" => vec![("terminalId", Id)],
        "file.save" => vec![
            ("workspaceId", Id),
            ("path", string(1, 4096)),
            ("content", string(0, 1048576)),
            ("expectedHash", string(64, 64)),
        ],
        "github.push" | "github.create" | "github.merge" => {
            let mut f = vec![
                ("workspaceId", Id),
                ("repository", Repo),
                ("branch", string(1, 255)),
                ("expectedHead", Hex(40, 64)),
            ];
            if kind == "github.create" {
                f.extend([
                    ("title", trimmed(1, 256)),
                    ("body", string(0, 65536)),
                    ("base", string(1, 255)),
                    ("draft", Bool),
                ]);
            }
            if kind == "github.merge" {
                f.extend([
                    ("number", Int(1, 9_007_199_254_740_991)),
                    ("method", Enum(&["merge", "squash", "rebase"])),
                    ("expectedPRHead", Hex(40, 40)),
                ]);
            }
            f
        }
        _ => return Err(invalid()),
    };
    if kind == "project.set-default-providers"
        && body.get("defaultConversationProvider").is_none()
        && body.get("defaultDelegationProvider").is_none()
    {
        return Err(invalid());
    }
    let parsed = parse_object(&body, &fields)?;
    let mut out = Map::new();
    out.insert("type".into(), json!(kind));
    for (k, v) in parsed.as_object().unwrap() {
        out.insert(k.clone(), v.clone());
    }
    Ok(Value::Object(out))
}
#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "4d654cfc-59db-44a0-96c8-0046ec720712";
    #[test]
    fn uuid_shape_matches_v1() {
        assert!(valid_uuid(ID));
        assert!(valid_uuid("00000000-0000-0000-0000-000000000000"));
        assert!(!valid_uuid(&ID.replace('-', "")));
        assert!(!valid_uuid("4d654cfc-59db-04a0-96c8-0046ec720712"));
    }
    #[test]
    fn defaults_trimming_and_unknown_fields() {
        let c = command(
            json!({"type":"workspace.create","projectId":ID,"name":"  example  ","extra":true}),
        )
        .unwrap();
        assert_eq!(
            c,
            json!({"type":"workspace.create","projectId":ID,"name":"example","skipStartup":false})
        );
        assert_eq!(
            command(json!({"type":"agent.send","agentId":ID,"text":" hi "})).unwrap()["mode"],
            "queue"
        );
    }
    #[test]
    fn null_is_not_optional_or_default() {
        assert!(command(json!({"type":"terminal.open","workspaceId":ID,"provider":null})).is_err());
        assert!(command(json!({"type":"terminal.open","workspaceId":ID,"resume":null})).is_err());
    }
    #[test]
    fn rejects_invalid_mutation_boundaries() {
        for (key, value) in [
            ("cols", json!(19)),
            ("cols", json!(401)),
            ("rows", json!(4)),
            ("rows", json!(201)),
            ("cols", json!(20.5)),
        ] {
            let mut c =
                json!({"type":"terminal.resize","terminalId":ID,"clientId":ID,"cols":80,"rows":24});
            c[key] = value;
            assert!(command(c).is_err());
        }
        assert!(command(json!({"type":"project.set-default-providers","projectId":ID})).is_err());
        assert!(command(json!({"type":"workspace.delete","workspaceId":ID,"cleanup":{"callerWorkspaceId":ID,"expectedHead":"a".repeat(40),"mergedPR":0}})).is_err());
    }
    #[test]
    fn unicode_limits_are_utf16_compatible() {
        assert!(command(json!({"type":"project.create","name":"😀".repeat(40)})).is_ok());
        assert!(command(json!({"type":"project.create","name":"😀".repeat(41)})).is_err());
    }
    #[test]
    fn watch_has_no_parallel_count_cap_but_rejects_duplicates() {
        let ids: Vec<_> = (0..100).map(|_| uuid::Uuid::new_v4().to_string()).collect();
        assert!(command(json!({"type":"agent.watch","agentId":ID,"taskIds":ids})).is_ok());
        assert!(command(json!({"type":"agent.watch","agentId":ID,"taskIds":[ID,ID]})).is_err());
    }
    #[test]
    fn journal_command_order_matches_legacy_normalization() {
        let value=command(json!({"prompt":"hello","workspaceId":ID,"type":"terminal.open","provider":"claude","unknown":true})).unwrap();
        assert_eq!(
            value.to_string(),
            format!(
                r#"{{"type":"terminal.open","workspaceId":"{}","provider":"claude","resume":false,"prompt":"hello"}}"#,
                ID
            )
        );
    }
}
