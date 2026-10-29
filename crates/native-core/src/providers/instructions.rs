use super::*;
impl Agents {
    /// The local bearer-token API is trusted. MCP supplies its launch-bound
    /// terminal identity; it never accepts a caller identity from tool arguments.
    pub async fn instruction(&self, c: &Value) -> Result<Value> {
        let mut s = self.state.lock().await;
        let mut a = get(&s, c["agentId"].as_str().ok_or("agent_missing")?)?;
        let terminal = c["sourceTerminalId"]
            .as_str()
            .ok_or("instruction_forbidden")?;
        let binding = self
            .store
            .call("get", json!({"table":"terminals","id":terminal}))
            .await?;
        let selected = s
            .claude
            .get(terminal)
            .and_then(|v| v.session.as_deref())
            .or_else(|| binding["agentId"].as_str())
            .ok_or("instruction_forbidden")?;
        let caller = s
            .agents
            .get(selected)
            .filter(|v| v.terminal_id == terminal && online(&s, v))
            .ok_or("instruction_forbidden")?;
        let actor = caller.id.clone();
        let action = c["action"].as_str().ok_or("instruction_action")?;
        if actor != a.id && (action == "consume" || a.parent_task_id.as_deref() != Some(&actor)) {
            return Err("instruction_forbidden".into());
        }
        if c["expectedRevision"].as_u64() != Some(a.revision) {
            return Err("instruction_revision_changed".into());
        }
        if c["expectedTurnId"] != json!(a.turn_id) {
            return Err("agent_turn_changed".into());
        }
        let key = c["instructionId"].as_str().ok_or("instruction_missing")?;
        let pending = a.pending.iter().position(|m| m.id == key && !m.report);
        let archived = a.instructions.iter().position(|m| m.id == key && !m.report);
        let m = pending
            .map(|i| &a.pending[i])
            .or_else(|| archived.map(|i| &a.instructions[i]))
            .ok_or("instruction_missing")?;
        if c["expectedState"] != m.state {
            return Err("instruction_state_changed".into());
        }
        if !matches!(m.state.as_str(), "queued" | "delivered")
            || action != "consume" && m.state != "queued"
        {
            return Err("instruction_not_retractable".into());
        }
        let mut m = m.clone();
        let replacement = match action {
            "consume" => {
                m.transition("consumed", Some(&actor));
                None
            }
            "cancel" => {
                m.transition("cancelled", Some(&actor));
                None
            }
            "supersede" => {
                let text = c["text"]
                    .as_str()
                    .filter(|v| !v.trim().is_empty())
                    .ok_or("instruction_text_required")?;
                m.transition("superseded", Some(&actor));
                let mut replacement = Message {
                    id: id(),
                    text: text.into(),
                    report: false,
                    state: queued(),
                    history: vec![],
                };
                replacement.transition("queued", Some(&actor));
                m.history.last_mut().unwrap()["replacementId"] = json!(replacement.id);
                Some(replacement)
            }
            _ => return Err("instruction_action".into()),
        };
        if let Some(i) = pending {
            a.pending.remove(i);
        }
        if let Some(i) = archived {
            a.instructions[i] = m.clone();
        } else {
            a.instructions.push(m.clone());
        }
        let replacement_id = replacement.as_ref().map(|m| m.id.clone());
        if let Some(replacement) = replacement {
            a.pending
                .insert(pending.unwrap_or(a.pending.len()), replacement);
        }
        // One durable row write atomically replaces the old instruction and
        // preserves every unrelated queued item. No delivery occurs under here.
        self.save(&mut s, a).await?;
        Ok(
            json!({"ok":true,"actorTaskId":actor,"instructionId":key,"state":m.state,"replacementId":replacement_id,"revision":s.agents[c["agentId"].as_str().unwrap()].revision}),
        )
    }
}
