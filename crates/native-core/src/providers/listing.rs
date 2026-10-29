use super::*;
use crate::contracts::valid_uuid;
use sha2::{Digest, Sha256};
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Options {
    task_ids: Option<Vec<String>>,
    workspace_id: Option<String>,
    status: Option<String>,
    #[serde(default)]
    summary_only: bool,
    since_revision: Option<u64>,
    since_epoch: Option<String>,
    since_filter: Option<String>,
    limit: Option<usize>,
    cursor: Option<String>,
}
impl Options {
    fn matches(&self, a: &Agent) -> bool {
        self.task_ids.as_ref().is_none_or(|ids| ids.contains(&a.id))
            && self
                .workspace_id
                .as_ref()
                .is_none_or(|w| *w == a.workspace_id)
            && self.status.as_ref().is_none_or(|s| *s == a.status)
    }
}
impl Agents {
    pub async fn query(&self, value: Value) -> Result<Value> {
        let mut o: Options = serde_json::from_value(value).map_err(|_| "invalid_list_options")?;
        if o.task_ids
            .as_ref()
            .is_some_and(|ids| ids.iter().any(|id| !valid_uuid(id)))
            || o.workspace_id.as_ref().is_some_and(|id| !valid_uuid(id))
            || o.status.as_ref().is_some_and(|s| {
                !["idle", "working", "waiting", "interrupted", "failed"].contains(&s.as_str())
            })
            || o.limit.is_some_and(|n| n == 0 || n > 500)
            || o.since_revision.is_some_and(|n| n > 9_007_199_254_740_991)
        {
            return Err("invalid_list_options".into());
        }
        if let Some(ids) = &mut o.task_ids {
            ids.sort();
            ids.dedup();
        }
        let filter = format!("{:x}", Sha256::digest(json!({"taskIds":o.task_ids,"workspaceId":o.workspace_id,"status":o.status,"summaryOnly":o.summary_only}).to_string().as_bytes()));
        let cursor = o.cursor.take();
        let fingerprint = format!("{:x}", Sha256::digest(serde_json::to_vec(&o).unwrap()));
        let s = self.state.lock().await;
        let revision = s.list_revision;
        let expired = o.since_revision.is_some_and(|r| {
            o.since_epoch.as_deref() != Some(&s.list_epoch)
                || r > revision
                || r < s.changes.front().map_or(revision, |v| v.0 - 1)
        });
        let mut offset = 0;
        if let Some(cursor) = cursor {
            let c: Value = serde_json::from_str(&cursor).map_err(|_| "invalid_list_cursor")?;
            if c["filter"] != fingerprint {
                return Ok(
                    json!({"agents":[],"removedTaskIds":[],"revision":revision,"epoch":s.list_epoch,"fullRefreshRequired":true,"reason":"filter_changed"}),
                );
            }
            if c["revision"] != revision || c["epoch"] != s.list_epoch {
                return Ok(
                    json!({"agents":[],"removedTaskIds":[],"revision":revision,"epoch":s.list_epoch,"fullRefreshRequired":true,"reason":"cursor_expired"}),
                );
            }
            offset = c["offset"]
                .as_u64()
                .and_then(|v| usize::try_from(v).ok())
                .ok_or("invalid_list_cursor")?;
        }
        if expired {
            return Ok(
                json!({"agents":[],"removedTaskIds":[],"revision":revision,"epoch":s.list_epoch,"fullRefreshRequired":true,"reason":"revision_expired"}),
            );
        }
        if o.since_revision.is_some() && o.since_filter.as_deref() != Some(&filter) {
            return Ok(
                json!({"agents":[],"removedTaskIds":[],"revision":revision,"epoch":s.list_epoch,"fullRefreshRequired":true,"reason":"filter_changed"}),
            );
        }
        let mut ids: Vec<String> = if let Some(after) = o.since_revision {
            s.changes
                .iter()
                .filter(|(r, key, workspace)| {
                    *r > after
                        && o.task_ids.as_ref().is_none_or(|ids| ids.contains(key))
                        && o.workspace_id.as_ref().is_none_or(|w| w == workspace)
                })
                .map(|(_, id, _)| id.clone())
                .collect()
        } else {
            s.agents
                .values()
                .filter(|a| o.matches(a))
                .map(|a| a.id.clone())
                .collect()
        };
        ids.sort();
        ids.dedup();
        let total = ids.len();
        if offset > total {
            return Err("invalid_list_cursor".into());
        }
        let end = (offset + o.limit.unwrap_or(500)).min(total);
        let mut rows = vec![];
        let mut removed = vec![];
        let mut current = HashMap::new();
        for key in &ids[offset..end] {
            let Some(a) = s.agents.get(key).filter(|a| o.matches(a)) else {
                removed.push(key.clone());
                continue;
            };
            if s.claude
                .get(&a.terminal_id)
                .and_then(|v| v.session.as_deref())
                == Some(&a.id)
            {
                current.insert(a.terminal_id.clone(), a.id.clone());
            }
            let row = if o.summary_only {
                json!({"id":a.id,"terminalId":a.terminal_id,"workspaceId":a.workspace_id,"name":a.name,"status":a.status,"provider":a.provider,"parentTaskId":a.parent_task_id,"turnId":a.turn_id,"lastTurnId":a.last_turn_id,"lastTurnStatus":a.last_turn_status,"channelState":a.channel_state,"updatedAt":a.updated_at,"revision":a.revision,"pendingCount":a.pending.len(),"reportCount":a.reports.len(),"hasUnreadReports":!a.reports.is_empty(),"unnotifiedReportCount":a.reports.iter().filter(|r| !r.notified).count(),"instructionCount":a.instructions.len(),"instructionHistoryPruned":a.instruction_history_pruned,"requestCount":a.requests.len(),"watchCount":a.watching.len()})
            } else {
                serde_json::to_value(a).map_err(|e| e.to_string())?
            };
            rows.push(row);
        }
        let next = (end < total).then(|| {
            json!({"revision":revision,"epoch":s.list_epoch,"filter":fingerprint,"offset":end})
                .to_string()
        });
        Ok(
            json!({"agents":rows,"removedTaskIds":removed,"revision":revision,"epoch":s.list_epoch,"filter":filter,"delta":o.since_revision.is_some(),"unchanged":o.since_revision == Some(revision),"fullRefreshRequired":false,"nextCursor":next,"currentSessionIds":current}),
        )
    }
}
