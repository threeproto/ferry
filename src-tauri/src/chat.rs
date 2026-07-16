//! Group chat backed by libchat's opinionated Logos stack.
//!
//! [`init`] opens a [`LogosChatClient`] (delegate identity, HTTP registry,
//! encrypted storage, embedded logos-delivery node) on a background thread,
//! then pumps the client's event channel into Tauri events the webview
//! subscribes to. Groups are GroupV2 (de-mls) conversations: invites and adds
//! are staged as proposals and land asynchronously when the steward commits.

use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use crossbeam_channel::Receiver;
use logos_chat::{ConversationClass, Event, GroupV2Config, LogosChatClient, LogosConfig};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

/// Lifecycle of the chat engine. Opening the client involves the registry and
/// the embedded node, so the app starts in `Starting` and the webview is told
/// when it settles.
pub enum ChatManager {
    Starting,
    Ready {
        client: LogosChatClient,
        address: String,
    },
    Failed(String),
    ShutDown,
}

pub struct ChatState(pub Mutex<ChatManager>);

impl Default for ChatState {
    fn default() -> Self {
        Self(Mutex::new(ChatManager::Starting))
    }
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Member {
    pub account: Option<String>,
    pub device: String,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatStatus {
    pub state: &'static str,
    pub address: Option<String>,
    pub error: Option<String>,
}

/// One decrypted observation forwarded to the webview as a `chat-event`.
#[derive(Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase", rename_all_fields = "camelCase")]
enum ChatEvent {
    ConversationStarted {
        convo_id: String,
        class: String,
    },
    MessageReceived {
        convo_id: String,
        content: String,
        sender: Member,
    },
    InboundError {
        message: String,
    },
}

/// Open the chat client off the main thread and report back via state +
/// `chat-ready` / `chat-error` events, then keep pumping chat events.
pub fn init(app: AppHandle) {
    thread::spawn(move || {
        let opened = open_client(&app);
        // The embedded node's runtime installs its own SIGINT/SIGTERM handlers
        // while starting, which would swallow Ctrl+C. Install ours after it so
        // they win, and route termination through Tauri's regular exit path
        // (which runs [`shutdown`]).
        let exit_handle = app.clone();
        if let Err(e) = ctrlc::set_handler(move || exit_handle.exit(0)) {
            eprintln!("could not install termination handler: {e}");
        }
        match opened {
            Ok((client, events)) => {
                let address = client.addr().to_string();
                *app.state::<ChatState>().0.lock().unwrap() = ChatManager::Ready {
                    client,
                    address: address.clone(),
                };
                let _ = app.emit("chat-ready", address);
                pump_events(&app, events);
            }
            Err(message) => {
                *app.state::<ChatState>().0.lock().unwrap() = ChatManager::Failed(message.clone());
                let _ = app.emit("chat-error", message);
            }
        };
    });
}

/// Dispose the chat client on app exit: joins the client's worker thread and
/// stops the embedded node via drop. A watchdog force-quits in case the native
/// node's stop hangs, so the process can never wedge on the way out.
pub fn shutdown(app: &AppHandle) {
    thread::spawn(|| {
        thread::sleep(std::time::Duration::from_secs(5));
        eprintln!("shutdown watchdog fired — forcing exit");
        std::process::exit(0);
    });
    let manager = std::mem::replace(
        &mut *app.state::<ChatState>().0.lock().unwrap(),
        ChatManager::ShutDown,
    );
    drop(manager);
}

fn open_client(app: &AppHandle) -> Result<(LogosChatClient, Receiver<Event>), String> {
    let data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("no app data directory: {e}"))?;
    std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;

    // A profile keeps its own database (and therefore its own account), so
    // several instances can run side by side: FERRY_PROFILE=alice ferry.
    let profile = std::env::var("FERRY_PROFILE").unwrap_or_else(|_| "default".into());
    let db_path = data_dir.join(format!("{profile}.db"));

    let mut config = LogosConfig::new(db_path.to_string_lossy(), "ferry");
    if let Ok(url) = std::env::var("FERRY_REGISTRY_URL") {
        config.set_registry_url(url);
    }
    config.set_group_v2_config(responsive_group_config());

    logos_chat::open(config).map_err(|e| e.to_string())
}

/// Snappier GroupV2 timers than the de-mls defaults (which wait ~60s before an
/// epoch steward commits a membership change). These trade a bit of batching
/// for member adds that land in a few seconds — a better fit for an interactive
/// desktop app where users watch invitees appear.
fn responsive_group_config() -> GroupV2Config {
    GroupV2Config {
        commit_inactivity_duration: Duration::from_secs(3),
        freeze_duration: Duration::from_millis(1500),
        voting_delay: Duration::from_secs(1),
        election_voting_delay: Duration::from_secs(1),
        consensus_timeout: Duration::from_secs(5),
        ..GroupV2Config::default()
    }
}

/// Forward every client event to the webview until the client shuts down.
fn pump_events(app: &AppHandle, events: Receiver<Event>) {
    for event in events.iter() {
        let payload = match event {
            Event::ConversationStarted { convo_id, class } => ChatEvent::ConversationStarted {
                convo_id: convo_id.to_string(),
                class: match class {
                    ConversationClass::Group => "group".into(),
                    ConversationClass::Private => "private".into(),
                },
            },
            Event::MessageReceived {
                convo_id,
                content,
                sender,
            } => ChatEvent::MessageReceived {
                convo_id: convo_id.to_string(),
                content: String::from_utf8_lossy(&content).into_owned(),
                sender: Member {
                    account: sender.account.map(|a| a.as_str().to_string()),
                    device: sender.local_identity.as_str().to_string(),
                },
            },
            Event::InboundError { message } => ChatEvent::InboundError { message },
            _ => continue,
        };
        let _ = app.emit("chat-event", payload);
    }
}

/// Run `f` against the ready client, or explain why it can't run yet.
fn with_client<T>(
    state: &ChatState,
    f: impl FnOnce(&mut LogosChatClient) -> Result<T, String>,
) -> Result<T, String> {
    match &mut *state.0.lock().unwrap() {
        ChatManager::Ready { client, .. } => f(client),
        ChatManager::Starting => Err("chat engine is still starting".into()),
        ChatManager::Failed(e) => Err(format!("chat engine failed to start: {e}")),
        ChatManager::ShutDown => Err("chat engine is shut down".into()),
    }
}

#[tauri::command]
pub fn chat_status(state: tauri::State<ChatState>) -> ChatStatus {
    match &*state.0.lock().unwrap() {
        ChatManager::Starting => ChatStatus {
            state: "starting",
            address: None,
            error: None,
        },
        ChatManager::Ready { address, .. } => ChatStatus {
            state: "ready",
            address: Some(address.clone()),
            error: None,
        },
        ChatManager::Failed(e) => ChatStatus {
            state: "failed",
            address: None,
            error: Some(e.clone()),
        },
        ChatManager::ShutDown => ChatStatus {
            state: "stopped",
            address: None,
            error: None,
        },
    }
}

#[tauri::command]
pub fn create_group(state: tauri::State<ChatState>, members: Vec<String>) -> Result<String, String> {
    with_client(&state, |client| {
        let refs: Vec<&str> = members.iter().map(String::as_str).collect();
        client
            .create_group_conversation(&refs)
            .map_err(|e| e.to_string())
    })
}

#[tauri::command]
pub fn add_members(
    state: tauri::State<ChatState>,
    convo_id: String,
    members: Vec<String>,
) -> Result<(), String> {
    with_client(&state, |client| {
        let refs: Vec<&str> = members.iter().map(String::as_str).collect();
        client
            .add_group_members(&convo_id, &refs)
            .map_err(|e| e.to_string())
    })
}

#[tauri::command]
pub fn send_group_message(
    state: tauri::State<ChatState>,
    convo_id: String,
    content: String,
) -> Result<(), String> {
    with_client(&state, |client| {
        client
            .send_message(&convo_id, content.as_bytes())
            .map_err(|e| e.to_string())
    })
}

#[tauri::command]
pub fn list_groups(state: tauri::State<ChatState>) -> Result<Vec<String>, String> {
    with_client(&state, |client| {
        client
            .list_conversations()
            .map(|ids| ids.into_iter().map(|id| id.to_string()).collect())
            .map_err(|e| e.to_string())
    })
}

#[tauri::command]
pub fn group_members(
    state: tauri::State<ChatState>,
    convo_id: String,
) -> Result<Vec<Member>, String> {
    with_client(&state, |client| {
        client
            .group_members(&convo_id)
            .map(|members| {
                members
                    .into_iter()
                    .map(|m| Member {
                        account: m.account.map(|a| a.as_str().to_string()),
                        device: m.local_identity.as_str().to_string(),
                    })
                    .collect()
            })
            .map_err(|e| e.to_string())
    })
}
