//! FRB-exposed chat API using libchat + mDNS transport.

use std::cell::RefCell;

use flutter_rust_bridge::frb;
use libchat::{ChatStorage, Context as ChatManager, Introduction, StorageConfig};

use crate::chat_state::{ChatState, PersistedState, Session, StoredMessage};
use crate::transport::{MdnsTransport, now_ms};

// ── Public types (FRB-visible) ────────────────────────────────────────────────

pub struct ChatMessage {
    pub from_self: bool,
    pub content: String,
    pub timestamp: u64,
}

pub struct ChatInfo {
    pub remote_user: String,
    pub chat_id: String,
    pub message_count: i32,
    pub is_active: bool,
}

pub struct ChatStatusInfo {
    pub user_name: String,
    pub address_hex: String,
    pub chat_count: i32,
    pub active_chat: String,
    pub tcp_port: u16,
}

// ── Thread-local state ────────────────────────────────────────────────────────

thread_local! {
    static CHAT: RefCell<Option<ChatState>> = const { RefCell::new(None) };
}

fn with_chat<T>(f: impl FnOnce(&mut ChatState) -> Result<T, String>) -> Result<T, String> {
    CHAT.with(|cell| {
        let mut borrow = cell.borrow_mut();
        match borrow.as_mut() {
            Some(s) => f(s),
            None => Err("Chat not initialized — call chat_init first".into()),
        }
    })
}

// ── FRB API ───────────────────────────────────────────────────────────────────

/// Initialize the chat engine. Safe to call multiple times (no-op after first).
#[frb(sync)]
pub fn chat_init(user_name: String, data_dir: String) -> Result<(), String> {
    CHAT.with(|cell| {
        if cell.borrow().is_some() {
            return Ok(());
        }
        std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;

        let db_path = format!("{}/{}.db", data_dir, user_name);
        let store =
            ChatStorage::new(StorageConfig::File(db_path)).map_err(|e| format!("{:?}", e))?;
        let manager = ChatManager::new_from_store(&user_name, store)
            .map_err(|e| format!("{:?}", e))?;

        let transport = MdnsTransport::new(&user_name)?;

        let state_path = format!("{}/{}_state.json", data_dir, user_name);
        let state: PersistedState = std::fs::read_to_string(&state_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        *cell.borrow_mut() = Some(ChatState {
            manager,
            transport,
            state,
            state_path,
        });
        Ok(())
    })
}

/// Returns true if the chat engine has been initialized.
#[frb(sync)]
pub fn chat_is_initialized() -> bool {
    CHAT.with(|cell| cell.borrow().is_some())
}

/// Create and return an intro bundle string for sharing out-of-band.
#[frb(sync)]
pub fn chat_get_intro() -> Result<String, String> {
    with_chat(|s| {
        let bytes = s
            .manager
            .create_intro_bundle()
            .map_err(|e| format!("{:?}", e))?;
        String::from_utf8(bytes).map_err(|e| e.to_string())
    })
}

/// Add a friend by providing their intro bundle; initiates the conversation.
#[frb(sync)]
pub fn chat_add_friend(remote_user: String, bundle: String) -> Result<(), String> {
    with_chat(|s| {
        if s.state.chats.contains_key(&remote_user) {
            return Err(format!("Already have a chat with '{}'", remote_user));
        }
        let intro = Introduction::try_from(bundle.trim().as_bytes())
            .map_err(|e| format!("Invalid intro bundle: {:?}", e))?;

        let (chat_id, envelopes) = s
            .manager
            .create_private_convo(&intro, "👋 Hello!".as_bytes())
            .map_err(|e| format!("{:?}", e))?;

        for env in envelopes {
            s.transport.send(&remote_user, env.data)?;
        }

        let session = Session {
            chat_id: chat_id.to_string(),
            remote_user: remote_user.clone(),
            messages: vec![StoredMessage {
                from_self: true,
                content: "👋 Hello!".into(),
                timestamp: now_ms(),
            }],
        };
        s.state.chats.insert(remote_user.clone(), session);
        s.state.active_chat = Some(remote_user);
        s.save();
        Ok(())
    })
}

/// List all chat sessions.
#[frb(sync)]
pub fn chat_list_chats() -> Vec<ChatInfo> {
    CHAT.with(|cell| {
        let borrow = cell.borrow();
        let Some(s) = borrow.as_ref() else {
            return vec![];
        };
        s.state
            .chats
            .values()
            .map(|sess| ChatInfo {
                remote_user: sess.remote_user.clone(),
                chat_id: sess.chat_id.clone(),
                message_count: sess.messages.len() as i32,
                is_active: s.state.active_chat.as_deref() == Some(&sess.remote_user),
            })
            .collect()
    })
}

/// Switch the active chat to `remote_user`.
#[frb(sync)]
pub fn chat_switch(remote_user: String) -> Result<(), String> {
    with_chat(|s| {
        if !s.state.chats.contains_key(&remote_user) {
            return Err(format!("No chat with '{}'", remote_user));
        }
        s.state.active_chat = Some(remote_user);
        s.save();
        Ok(())
    })
}

/// Delete the chat with `remote_user`.
#[frb(sync)]
pub fn chat_delete(remote_user: String) -> Result<(), String> {
    with_chat(|s| {
        if s.state.chats.remove(&remote_user).is_none() {
            return Err(format!("No chat with '{}'", remote_user));
        }
        if s.state.active_chat.as_deref() == Some(&remote_user) {
            s.state.active_chat = s.state.chats.keys().next().cloned();
        }
        s.save();
        Ok(())
    })
}

/// Send a text message in the currently active chat.
#[frb(sync)]
pub fn chat_send(content: String) -> Result<(), String> {
    with_chat(|s| {
        let active = s
            .state
            .active_chat
            .clone()
            .ok_or_else(|| "No active chat — switch to one first".to_string())?;
        let (chat_id, remote_user) = {
            let sess = s
                .state
                .chats
                .get(&active)
                .ok_or_else(|| "Session not found".to_string())?;
            (sess.chat_id.clone(), sess.remote_user.clone())
        };

        let envelopes = s
            .manager
            .send_content(&chat_id, content.as_bytes())
            .map_err(|e| format!("{:?}", e))?;

        for env in envelopes {
            s.transport.send(&remote_user, env.data)?;
        }

        if let Some(sess) = s.state.chats.get_mut(&active) {
            sess.messages.push(StoredMessage {
                from_self: true,
                content,
                timestamp: now_ms(),
            });
        }
        s.save();
        Ok(())
    })
}

/// Poll for incoming envelopes. Returns names of users who sent new messages.
#[frb(sync)]
pub fn chat_poll() -> Result<Vec<String>, String> {
    with_chat(|s| {
        let mut senders = Vec::new();
        while let Some(env) = s.transport.try_recv() {
            match s.manager.handle_payload(&env.data) {
                Ok(Some(content)) => {
                    let from = env.from.clone();
                    if !s.state.chats.contains_key(&from) {
                        s.state.chats.insert(
                            from.clone(),
                            Session {
                                chat_id: content.conversation_id.clone(),
                                remote_user: from.clone(),
                                messages: vec![],
                            },
                        );
                        if s.state.active_chat.is_none() {
                            s.state.active_chat = Some(from.clone());
                        }
                    }
                    let text = String::from_utf8_lossy(&content.data).to_string();
                    if !text.is_empty() {
                        if let Some(sess) = s.state.chats.get_mut(&from) {
                            sess.messages.push(StoredMessage {
                                from_self: false,
                                content: text,
                                timestamp: env.timestamp,
                            });
                        }
                    }
                    senders.push(from);
                    s.save();
                }
                Ok(None) | Err(_) => {}
            }
        }
        Ok(senders)
    })
}

/// Get all messages for the active chat.
#[frb(sync)]
pub fn chat_get_messages() -> Vec<ChatMessage> {
    CHAT.with(|cell| {
        let borrow = cell.borrow();
        let Some(s) = borrow.as_ref() else {
            return vec![];
        };
        let Some(active) = &s.state.active_chat else {
            return vec![];
        };
        let Some(sess) = s.state.chats.get(active) else {
            return vec![];
        };
        sess.messages
            .iter()
            .map(|m| ChatMessage {
                from_self: m.from_self,
                content: m.content.clone(),
                timestamp: m.timestamp,
            })
            .collect()
    })
}

/// Returns the active chat's remote_user name, or empty string if none.
#[frb(sync)]
pub fn chat_get_active() -> String {
    CHAT.with(|cell| {
        cell.borrow()
            .as_ref()
            .and_then(|s| s.state.active_chat.clone())
            .unwrap_or_default()
    })
}

/// Status info for display.
#[frb(sync)]
pub fn chat_get_status() -> ChatStatusInfo {
    CHAT.with(|cell| {
        let borrow = cell.borrow();
        let Some(s) = borrow.as_ref() else {
            return ChatStatusInfo {
                user_name: String::new(),
                address_hex: String::new(),
                chat_count: 0,
                active_chat: String::new(),
                tcp_port: 0,
            };
        };
        ChatStatusInfo {
            user_name: s.manager.installation_name().to_string(),
            address_hex: hex_encode(s.manager.installation_key().as_bytes()),
            chat_count: s.state.chats.len() as i32,
            active_chat: s.state.active_chat.clone().unwrap_or_default(),
            tcp_port: s.transport.tcp_port,
        }
    })
}

/// Peers currently visible via mDNS.
#[frb(sync)]
pub fn chat_list_peers() -> Vec<String> {
    CHAT.with(|cell| {
        cell.borrow()
            .as_ref()
            .map(|s| s.transport.list_peers())
            .unwrap_or_default()
    })
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}
