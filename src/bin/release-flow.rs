use anyhow::Result;
use release_flow::cli::{self, actions::Action};
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("error: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<()> {
    match cli::start()? {
        Action::Status { json } => cli::actions::status::run(json),
        Action::Plan { bump, json } => cli::actions::plan::run(bump, json),
    }
}
