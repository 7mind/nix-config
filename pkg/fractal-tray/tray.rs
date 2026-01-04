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
}

impl FractalTray {
    pub fn new(tx: mpsc::UnboundedSender<TrayCommand>) -> Self {
        Self { tx }
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

pub fn spawn_tray() -> mpsc::UnboundedReceiver<TrayCommand> {
    let (tx, rx) = mpsc::unbounded_channel();
    let tray = FractalTray::new(tx);

    info!("Spawning system tray icon...");

    // Spawn on fractal's tokio runtime
    RUNTIME.spawn(async move {
        match tray.spawn().await {
            Ok(handle) => {
                info!("System tray icon created successfully");
                // Keep the handle alive to keep the tray running
                let _ = handle;
                std::future::pending::<()>().await;
            }
            Err(e) => {
                warn!("Failed to create tray icon: {e}");
            }
        }
    });

    rx
}
