use crate::{release::version::{self, Bump}, repository::Snapshot};
use anyhow::Result;
use serde_json::json;

pub fn run(bump: Bump, as_json: bool) -> Result<()> {
    let snapshot = Snapshot::inspect()?;
    let proposed = version::next(&snapshot.version, bump)?;
    let mut blockers = Vec::new();
    if snapshot.branch != "develop" {
        blockers.push(format!("expected develop, currently on {}", snapshot.branch));
    }
    if !snapshot.clean {
        blockers.push("working tree is dirty".to_owned());
    }
    if snapshot.latest_tag.as_ref().is_some_and(|tag| proposed <= *tag) {
        blockers.push("proposed version is not newer than the latest local tag".to_owned());
    }
    if as_json {
        let value = json!({
            "base_version": snapshot.version.to_string(),
            "bump": bump.as_str(),
            "proposed_version": proposed.to_string(),
            "branch": snapshot.branch,
            "commit": snapshot.commit,
            "eligible_locally": blockers.is_empty(),
            "blockers": blockers,
            "note": "Read-only local preview; remote CI and promotion guards are not implemented yet",
        });
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }
    println!("Current version  {}", snapshot.version);
    println!("Proposed {}   {}", bump.as_str(), proposed);
    if blockers.is_empty() {
        println!("Local preflight  ready (remote CI not evaluated)");
    } else {
        println!("Local preflight  blocked:");
        for blocker in blockers {
            println!("  - {blocker}");
        }
    }
    println!("This command does not change files, branches, or tags.");
    Ok(())
}
