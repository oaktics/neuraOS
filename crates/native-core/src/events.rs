use serde::{Serialize,Deserialize};
#[derive(Debug,Clone,Default,Serialize,Deserialize)]
pub struct Change {pub state:bool,pub terminals:Vec<String>,#[serde(default)]pub browser:bool}
