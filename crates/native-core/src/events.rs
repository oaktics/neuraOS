use serde::{Deserialize, Serialize};
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Change {
    pub state: bool,
    #[serde(default, rename = "agentTerminals")]
    pub agent_terminals: Vec<String>,
    pub terminals: Vec<String>,
    #[serde(default)]
    pub browser: bool,
}
