use crate::cli::{actions::Action, commands, dispatch, telemetry};
use anyhow::Result;

/// Initialize the CLI and select an action without executing domain logic.
pub fn start() -> Result<Action> {
    let matches = commands::new().get_matches();
    telemetry::init(matches.get_count("verbose"))?;
    dispatch::handler(&matches)
}
