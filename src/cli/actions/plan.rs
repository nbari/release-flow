use crate::{
    release::{plan::PlanReport, version::Bump},
    repository::Snapshot,
};
use anyhow::Result;
use std::process::ExitCode;

/// Run the release planning preview action.
///
/// # Errors
/// Returns an error if repository inspection fails or planning calculation fails.
pub fn run(bump: Bump, as_json: bool) -> Result<ExitCode> {
    let snapshot = Snapshot::inspect()?;
    let report = PlanReport::create(&snapshot, bump)?;

    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
        return Ok(ExitCode::SUCCESS);
    }

    println!("Current version  {}", report.base_version);
    println!("Proposed {}   {}", bump.as_str(), report.proposed_version);
    println!("Proposed tag     {}", report.proposed_tag);
    println!(
        "Branch           {}",
        report.branch.as_deref().unwrap_or("HEAD (detached)")
    );
    println!("Commit           {}", report.commit);

    if !report.tag_conflicts.is_empty() {
        println!("Tag conflicts    {}", report.tag_conflicts.join(", "));
    }

    if report.eligible_locally {
        println!("Local preflight  ready (remote CI evaluated separately by `check`)");
    } else {
        println!("Local preflight  blocked:");
        for blocker in &report.blockers {
            println!("  - {blocker}");
        }
    }

    if !report.observations.is_empty() {
        println!("Observations:");
        for obs in &report.observations {
            println!("  - {obs}");
        }
    }
    if !report.warnings.is_empty() {
        println!("Warnings:");
        for warning in &report.warnings {
            println!("  - {warning}");
        }
    }

    println!("This command does not change files, branches, or tags.");
    Ok(ExitCode::SUCCESS)
}
