use crate::repository::Snapshot;
use anyhow::Result;
use std::process::ExitCode;

/// Run the repository status inspection action.
///
/// # Errors
/// Returns an error if repository inspection fails or serialization fails.
pub fn run(as_json: bool) -> Result<ExitCode> {
    let snapshot = Snapshot::inspect()?.with_actions();
    if as_json {
        println!("{}", serde_json::to_string_pretty(&snapshot)?);
        return Ok(ExitCode::SUCCESS);
    }

    println!("Repository       {}", snapshot.root.display());
    println!(
        "Remote URL       {}",
        snapshot.remote_url.as_deref().unwrap_or("none")
    );
    println!(
        "Branch           {}",
        snapshot.branch.as_deref().unwrap_or("HEAD (detached)")
    );
    println!("Commit           {}", snapshot.commit);
    println!(
        "Working tree     {}",
        if snapshot.clean { "clean" } else { "dirty" }
    );
    println!("Cargo version    {}", snapshot.version);
    println!(
        "Latest tag       {} (local)",
        snapshot
            .latest_local_tag
            .as_ref()
            .map_or_else(|| "none".into(), ToString::to_string)
    );
    println!(
        "Latest tag       {} (remote)",
        snapshot.latest_remote_tag.as_ref().map_or_else(
            || {
                snapshot
                    .remote_tags_error
                    .as_deref()
                    .unwrap_or("none")
                    .to_string()
            },
            ToString::to_string
        )
    );

    println!("Branch relations");
    if let Some(ab) = snapshot.branch_relationships.current_vs_upstream {
        println!(
            "  upstream tracking: {} ahead, {} behind",
            ab.ahead, ab.behind
        );
    } else {
        println!("  upstream tracking: none configured");
    }

    if let Some(ab) = snapshot.branch_relationships.develop_vs_main {
        println!(
            "  develop vs main: develop has {} commit(s) ahead, {} behind main",
            ab.ahead, ab.behind
        );
    }

    println!("GitHub Actions");
    if let Some(runs) = &snapshot.actions {
        if runs.is_empty() {
            println!("  no workflow runs found");
        } else {
            for run in runs {
                let conclusion = run.conclusion.as_deref().unwrap_or("-");
                let sha_match = if run.head_sha == snapshot.commit {
                    "(exact commit SHA match)"
                } else {
                    "(different SHA)"
                };
                let short_sha = run.head_sha.get(..7).unwrap_or(&run.head_sha);
                println!(
                    "  {} / {} ({}) {} {} {}",
                    run.name, run.head_branch, short_sha, run.status, conclusion, sha_match
                );
            }
        }
    } else {
        println!(
            "  {}",
            snapshot
                .actions_error
                .as_deref()
                .unwrap_or("unavailable (offline or gh not authenticated)")
        );
    }

    if !snapshot.warnings.is_empty() {
        println!("Warnings");
        for warning in &snapshot.warnings {
            println!("  - {warning}");
        }
    }

    Ok(ExitCode::SUCCESS)
}
