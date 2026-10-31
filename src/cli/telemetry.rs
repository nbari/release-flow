use anyhow::{Context, Result};

/// Keep application diagnostics on stderr, leaving stdout available for JSON.
///
/// # Errors
///
/// Returns an error if tracing initialization fails.
pub fn init(verbosity: u8) -> Result<()> {
    let filter = match verbosity {
        0 => "warn",
        1 => "info",
        _ => "debug",
    };
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .try_init()
        .map_err(|error| anyhow::anyhow!("{error}"))
        .context("initialize release-flow diagnostics")
}
