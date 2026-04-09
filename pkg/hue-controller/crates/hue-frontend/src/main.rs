mod app;
mod components;
mod ws;

fn main() {
    leptos::mount::mount_to_body(app::App);
}
