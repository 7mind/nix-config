use ksni::{menu::StandardItem, Icon, MenuItem, Tray, TrayMethods};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::mpsc;
use tracing::{info, warn};

use crate::RUNTIME;

#[derive(Debug)]
pub enum TrayCommand {
    Show,
    Quit,
}

pub struct FractalTray {
    tx: mpsc::UnboundedSender<TrayCommand>,
    has_unread: Arc<AtomicBool>,
}

impl FractalTray {
    pub fn new(tx: mpsc::UnboundedSender<TrayCommand>, has_unread: Arc<AtomicBool>) -> Self {
        Self { tx, has_unread }
    }
}

impl Tray for FractalTray {
    fn icon_name(&self) -> String {
        // Use the installed Fractal icon
        "org.gnome.Fractal".to_string()
    }

    fn icon_pixmap(&self) -> Vec<Icon> {
        // Fallback: simple 22x22 blue icon if icon_name doesn't work
        let size = 22;
        let mut data = Vec::with_capacity((size * size * 4) as usize);
        for _ in 0..(size * size) {
            // ARGB format: blue color
            data.push(255); // A
            data.push(100); // R
            data.push(150); // G
            data.push(237); // B - cornflower blue
        }
        vec![Icon {
            width: size,
            height: size,
            data,
        }]
    }

    fn title(&self) -> String {
        "Fractal".to_string()
    }

    fn id(&self) -> String {
        "org.gnome.Fractal".to_string()
    }

    fn status(&self) -> ksni::Status {
        if self.has_unread.load(Ordering::Relaxed) {
            ksni::Status::NeedsAttention
        } else {
            ksni::Status::Passive
        }
    }

    fn attention_icon_name(&self) -> String {
        "org.gnome.Fractal".to_string()
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        info!("Tray icon activated");
        let _ = self.tx.send(TrayCommand::Show);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let tx_show = self.tx.clone();
        let tx_quit = self.tx.clone();
        vec![
            StandardItem {
                label: "Show Fractal".into(),
                activate: Box::new(move |_| {
                    info!("Tray menu: Show clicked");
                    let _ = tx_show.send(TrayCommand::Show);
                }),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(move |_| {
                    info!("Tray menu: Quit clicked");
                    let _ = tx_quit.send(TrayCommand::Quit);
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

pub struct TrayHandle {
    rx: Option<mpsc::UnboundedReceiver<TrayCommand>>,
    has_unread: Arc<AtomicBool>,
    update_tx: mpsc::UnboundedSender<()>,
}

impl TrayHandle {
    pub fn take_receiver(&mut self) -> Option<mpsc::UnboundedReceiver<TrayCommand>> {
        self.rx.take()
    }

    pub fn set_has_unread(&self, value: bool) {
        let old = self.has_unread.swap(value, Ordering::Relaxed);
        if old != value {
            let _ = self.update_tx.send(());
        }
    }
}

pub fn spawn_tray() -> TrayHandle {
    let (tx, rx) = mpsc::unbounded_channel();
    let (update_tx, mut update_rx) = mpsc::unbounded_channel::<()>();
    let has_unread = Arc::new(AtomicBool::new(false));
    let has_unread_clone = has_unread.clone();
    let tray = FractalTray::new(tx, has_unread_clone);

    info!("Spawning system tray icon...");

    RUNTIME.spawn(async move {
        match tray.spawn().await {
            Ok(handle) => {
                info!("System tray icon created successfully");
                while update_rx.recv().await.is_some() {
                    handle.update(|_| {});
                }
            }
            Err(e) => {
                warn!("Failed to create tray icon: {e}");
            }
        }
    });

    TrayHandle { rx: Some(rx), has_unread, update_tx }
}
