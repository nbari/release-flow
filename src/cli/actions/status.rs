use crate::repository::Snapshot;
use anyhow::Result;
use serde_json::{Value, json};

pub fn run(as_json: bool) -> Result<()> {
    let snapshot = Snapshot::inspect()?.with_actions();
    if as_json {
        let value = json!({
            "repository": snapshot.root.display().to_string(),
            "branch": snapshot.branch,
            "commit": snapshot.commit,
            "clean": snapshot.clean,
            "cargo_version": snapshot.version.to_string(),
            "latest_local_tag": snapshot.latest_tag.map(|v| v.to_string()),
            "github_actions": snapshot.actions,
            "github_actions_error": snapshot.actions_error,
        });
        println!("{}", serde_json::to_string_pretty(&value)?);
        return Ok(());
    }
    println!("Repository     {}", snapshot.root.display());
    println!("Branch         {}", snapshot.branch);
    println!("Commit         {}", snapshot.commit);
    println!(
        "Working tree   {}",
        if snapshot.clean { "clean" } else { "dirty" }
    );
    println!("Cargo version  {}", snapshot.version);
    println!(
        "Latest tag     {} (local)",
        snapshot
            .latest_tag
            .map_or_else(|| "none".into(), |v| v.to_string())
    );
    println!("GitHub Actions");
    if let Some(Value::Array(runs)) = snapshot.actions {
        if runs.is_empty() {
            println!("  no workflow runs found");
        }
        for run in &runs {
            let name = field(run, "name");
            let branch = field(run, "headBranch");
            let status = field(run, "status");
            let conclusion = field(run, "conclusion");
            println!("  {name} / {branch}  {status} {conclusion}");
        }
    } else {
        println!(
            "  {}",
            snapshot.actions_error.as_deref().unwrap_or("unavailable")
        );
    }
    Ok(())
}

fn field<'a>(value: &'a Value, key: &str) -> &'a str {
    value.get(key).and_then(Value::as_str).unwrap_or("-")
}
