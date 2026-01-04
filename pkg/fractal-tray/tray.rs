use ksni::{menu::StandardItem, Icon, MenuItem, Tray, TrayMethods};
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
    pub has_unread: bool,
}

impl FractalTray {
    pub fn new(tx: mpsc::UnboundedSender<TrayCommand>) -> Self {
        Self { tx, has_unread: false }
    }
}

impl Tray for FractalTray {
    fn icon_name(&self) -> String {
        "org.gnome.Fractal".to_string()
    }

    fn overlay_icon_pixmap(&self) -> Vec<Icon> {
        if !self.has_unread {
            return vec![];
        }
        // Red notification dot overlay
        let size = 24;
        let mut data = Vec::with_capacity((size * size * 4) as usize);
        let dot_radius = 5i32;
        let dot_center_x = size - dot_radius - 1;
        let dot_center_y = dot_radius + 1;

        for y in 0..size {
            for x in 0..size {
                let dx = x - dot_center_x;
                let dy = y - dot_center_y;
                let in_dot = dx * dx + dy * dy <= dot_radius * dot_radius;

                if in_dot {
                    // Red dot
                    data.push(255); // A
                    data.push(220); // R
                    data.push(50);  // G
                    data.push(50);  // B
                } else {
                    // Transparent
                    data.push(0); // A
                    data.push(0); // R
                    data.push(0); // G
                    data.push(0); // B
                }
            }
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

    fn category(&self) -> ksni::Category {
        ksni::Category::Communications
    }

    fn status(&self) -> ksni::Status {
        if self.has_unread {
            ksni::Status::NeedsAttention
        } else {
            ksni::Status::Active
        }
    }

    fn attention_icon_name(&self) -> String {
        self.icon_name()
    }

    fn tool_tip(&self) -> ksni::ToolTip {
        let description = if self.has_unread {
            "Unread messages"
        } else {
            "Fractal"
        };
        ksni::ToolTip {
            icon_name: self.icon_name(),
            title: "Fractal".to_string(),
            description: description.to_string(),
            ..Default::default()
        }
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

#[derive(Debug)]
pub struct TrayHandle {
    rx: Option<mpsc::UnboundedReceiver<TrayCommand>>,
    update_tx: mpsc::UnboundedSender<bool>,
}

impl TrayHandle {
    pub fn take_receiver(&mut self) -> Option<mpsc::UnboundedReceiver<TrayCommand>> {
        self.rx.take()
    }

    pub fn set_has_unread(&self, value: bool) {
        info!("Tray set_has_unread: {}", value);
        let _ = self.update_tx.send(value);
    }
}

pub fn spawn_tray() -> TrayHandle {
    let (tx, rx) = mpsc::unbounded_channel();
    let (update_tx, mut update_rx) = mpsc::unbounded_channel::<bool>();
    let tray = FractalTray::new(tx);

    info!("Spawning system tray icon...");

    RUNTIME.spawn(async move {
        match tray.spawn().await {
            Ok(handle) => {
                info!("System tray icon created successfully");
                while let Some(has_unread) = update_rx.recv().await {
                    info!("Updating tray icon, has_unread: {}", has_unread);
                    handle.update(|tray| {
                        tray.has_unread = has_unread;
                    }).await;
                    info!("Tray icon update complete");
                }
            }
            Err(e) => {
                warn!("Failed to create tray icon: {e}");
            }
        }
    });

    TrayHandle { rx: Some(rx), update_tx }
}
