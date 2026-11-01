use crate::{
    release::check::{CheckReport, Verdict},
    repository::Snapshot,
};
use anyhow::Result;
use std::process::ExitCode;

/// Run the release readiness check action.
///
/// # Errors
/// Returns an error if repository inspection fails or JSON serialization fails.
pub fn run(as_json: bool, local_only: bool) -> Result<ExitCode> {
    let snapshot = if local_only {
        Snapshot::inspect_local()?
    } else {
        Snapshot::inspect()?.with_actions()
    };
    let report = CheckReport::evaluate(&snapshot, local_only);

    if as_json {
        println!("{}", serde_json::to_string_pretty(&report)?);
    } else {
        println!("Release Readiness Check");
        println!("=======================");
        for finding in &report.findings {
            let symbol = match finding.verdict {
                Verdict::Pass => "[PASS]   ",
                Verdict::Fail => "[FAIL]   ",
                Verdict::Unknown => "[UNKNOWN]",
            };
            println!("{symbol} {:<24} {}", finding.id, finding.message);
        }
        println!("-----------------------");
        println!(
            "Summary: {} passed, {} failed, {} unknown",
            report.summary.pass, report.summary.fail, report.summary.unknown
        );
        if report.eligible {
            println!("Verdict: ELIGIBLE FOR RELEASE");
        } else {
            println!("Verdict: BLOCKED (release gate failed closed)");
        }
        if !report.warnings.is_empty() {
            println!("\nWarnings:");
            for warning in &report.warnings {
                println!("  - {warning}");
            }
        }
    }

    if report.eligible {
        Ok(ExitCode::SUCCESS)
    } else {
        Ok(ExitCode::FAILURE)
    }
}
