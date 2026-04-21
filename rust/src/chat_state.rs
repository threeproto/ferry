//! Internal chat state — not exposed via FRB.

use std::collections::HashMap;

use libchat::{ChatStorage, Context as ChatManager};
use serde::{Deserialize, Serialize};

use crate::transport::MdnsTransport;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub chat_id: String,
    pub remote_user: String,
    pub messages: Vec<StoredMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredMessage {
    pub from_self: bool,
    pub content: String,
    pub timestamp: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct PersistedState {
    pub chats: HashMap<String, Session>,
    pub active_chat: Option<String>,
}

pub struct ChatState {
    pub manager: ChatManager<ChatStorage>,
    pub transport: MdnsTransport,
    pub state: PersistedState,
    pub state_path: String,
}

impl ChatState {
    pub fn save(&self) {
        if let Ok(json) = serde_json::to_string_pretty(&self.state) {
            let _ = std::fs::write(&self.state_path, json);
        }
    }
}
