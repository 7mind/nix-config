use ksni::{menu::StandardItem, MenuItem, Tray, TrayMethods};
use tokio::sync::mpsc;

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
        "org.gnome.Fractal".to_string()
    }

    fn title(&self) -> String {
        "Fractal".to_string()
    }

    fn id(&self) -> String {
        "org.gnome.Fractal".to_string()
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = self.tx.send(TrayCommand::Show);
    }

    fn menu(&self) -> Vec<MenuItem<Self>> {
        let tx_show = self.tx.clone();
        let tx_quit = self.tx.clone();
        vec![
            StandardItem {
                label: "Show Fractal".into(),
                activate: Box::new(move |_| {
                    let _ = tx_show.send(TrayCommand::Show);
                }),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(move |_| {
                    let _ = tx_quit.send(TrayCommand::Quit);
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

pub async fn spawn_tray() -> mpsc::UnboundedReceiver<TrayCommand> {
    let (tx, rx) = mpsc::unbounded_channel();
    let tray = FractalTray::new(tx);

    tokio::spawn(async move {
        match tray.spawn().await {
            Ok(_handle) => {
                // Keep the tray running forever
                std::future::pending::<()>().await;
            }
            Err(e) => {
                tracing::warn!("Failed to create tray icon: {e}");
            }
        }
    });

    rx
}
