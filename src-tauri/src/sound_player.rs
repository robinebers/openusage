use std::fs::File;
use std::path::PathBuf;
use std::sync::{mpsc, Mutex, OnceLock};

use rodio::Decoder;
use tauri::{AppHandle, Manager};

static SOUND_QUEUE: OnceLock<Mutex<Option<mpsc::Sender<PathBuf>>>> = OnceLock::new();

fn queue_slot() -> &'static Mutex<Option<mpsc::Sender<PathBuf>>> {
    SOUND_QUEUE.get_or_init(|| Mutex::new(None))
}

fn ensure_worker() -> Result<mpsc::Sender<PathBuf>, String> {
    let mut slot = queue_slot()
        .lock()
        .map_err(|e| format!("failed to lock sound queue: {}", e))?;

    if let Some(sender) = slot.as_ref() {
        return Ok(sender.clone());
    }

    let (sender, receiver) = mpsc::channel::<PathBuf>();
    std::thread::spawn(move || {
        let sink_handle = match rodio::DeviceSinkBuilder::open_default_sink() {
            Ok(handle) => handle,
            Err(error) => {
                log::error!("Failed to open default audio output: {}", error);
                return;
            }
        };
        let player = rodio::Player::connect_new(&sink_handle.mixer());

        for path in receiver {
            match File::open(&path)
                .map_err(|error| error.to_string())
                .and_then(|file| Decoder::try_from(file).map_err(|error| error.to_string()))
            {
                Ok(source) => {
                    player.append(source);
                    player.sleep_until_end();
                }
                Err(error) => {
                    log::error!("Failed to play notification sound {:?}: {}", path, error);
                }
            }
        }
    });

    *slot = Some(sender.clone());
    Ok(sender)
}

#[tauri::command]
pub fn play_notification_sound(app_handle: AppHandle, file_name: String) -> Result<(), String> {
    if file_name.contains('/') || file_name.contains('\\') || !file_name.ends_with(".mp3") {
        return Err("invalid notification sound file name".to_string());
    }

    let path = app_handle
        .path()
        .resolve(
            format!("resources/notification_sounds/{}", file_name),
            tauri::path::BaseDirectory::Resource,
        )
        .map_err(|error| format!("failed to resolve notification sound: {}", error))?;

    let sender = ensure_worker()?;
    if let Err(error) = sender.send(path) {
        if let Ok(mut slot) = queue_slot().lock() {
            *slot = None;
        }
        return Err(format!("failed to queue notification sound: {}", error));
    }

    Ok(())
}
