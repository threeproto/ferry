mod chat;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(chat::ChatState::default())
        .setup(|app| {
            chat::init(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            chat::chat_status,
            chat::create_group,
            chat::add_members,
            chat::send_group_message,
            chat::list_groups,
            chat::group_members,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
