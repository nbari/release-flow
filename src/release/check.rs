use crate::repository::Snapshot;
use serde::{Deserialize, Serialize};

/// Verdict of an individual release readiness check.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Pass,
    Fail,
    Unknown,
}

impl Verdict {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Pass => "pass",
            Self::Fail => "fail",
            Self::Unknown => "unknown",
        }
    }
}

/// A single preflight finding with identifier, verdict, and explanation.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CheckFinding {
    pub id: String,
    pub verdict: Verdict,
    pub message: String,
}

/// Count summary of findings by verdict.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct CheckSummary {
    pub pass: usize,
    pub fail: usize,
    pub unknown: usize,
}

/// Complete report of release eligibility.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CheckReport {
    pub eligible: bool,
    pub summary: CheckSummary,
    pub findings: Vec<CheckFinding>,
    pub warnings: Vec<String>,
}

impl CheckReport {
    /// Evaluate release invariants against a repository snapshot.
    ///
    /// When `local_only` is false, remote CI and tracking branches are verified.
    /// A release gate fails closed: any `Fail` or `Unknown` finding results in `eligible = false`.
    #[must_use]
    pub fn evaluate(snapshot: &Snapshot, local_only: bool) -> Self {
        let mut findings = evaluate_local_invariants(snapshot);

        if !local_only {
            findings.extend(evaluate_remote_invariants(snapshot));
        }

        let pass_count = findings
            .iter()
            .filter(|f| f.verdict == Verdict::Pass)
            .count();
        let fail_count = findings
            .iter()
            .filter(|f| f.verdict == Verdict::Fail)
            .count();
        let unknown_count = findings
            .iter()
            .filter(|f| f.verdict == Verdict::Unknown)
            .count();

        // Fail-closed invariant: must have 0 failures and 0 unknowns to be eligible
        let eligible = fail_count == 0 && unknown_count == 0;

        Self {
            eligible,
            summary: CheckSummary {
                pass: pass_count,
                fail: fail_count,
                unknown: unknown_count,
            },
            findings,
            warnings: snapshot.warnings.clone(),
        }
    }
}

fn evaluate_local_invariants(snapshot: &Snapshot) -> Vec<CheckFinding> {
    let mut findings = Vec::new();

    // 1. Valid Git repository
    findings.push(CheckFinding {
        id: "git_repository".to_string(),
        verdict: Verdict::Pass,
        message: format!(
            "Valid Git repository detected at {}",
            snapshot.root.display()
        ),
    });

    // 2. Clean working tree
    if snapshot.clean {
        findings.push(CheckFinding {
            id: "clean_working_tree".to_string(),
            verdict: Verdict::Pass,
            message: "Working tree is clean".to_string(),
        });
    } else {
        findings.push(CheckFinding {
            id: "clean_working_tree".to_string(),
            verdict: Verdict::Fail,
            message: "Working tree has uncommitted modifications or untracked files".to_string(),
        });
    }

    // 3. Valid Cargo version
    if !snapshot.version.pre.is_empty() || !snapshot.version.build.is_empty() {
        findings.push(CheckFinding {
            id: "cargo_version".to_string(),
            verdict: Verdict::Fail,
            message: format!(
                "Cargo version {} contains prerelease or build metadata",
                snapshot.version
            ),
        });
    } else {
        findings.push(CheckFinding {
            id: "cargo_version".to_string(),
            verdict: Verdict::Pass,
            message: format!(
                "Cargo manifest declares valid stable version {}",
                snapshot.version
            ),
        });
    }

    // 4. Correct branch context (must be develop, not detached)
    if snapshot.branch_relationships.is_detached {
        findings.push(CheckFinding {
            id: "branch_context".to_string(),
            verdict: Verdict::Fail,
            message: "Detached HEAD state; releases must originate from 'develop' branch"
                .to_string(),
        });
    } else if snapshot.branch.as_deref() == Some("develop") {
        findings.push(CheckFinding {
            id: "branch_context".to_string(),
            verdict: Verdict::Pass,
            message: "Currently on integration branch 'develop'".to_string(),
        });
    } else {
        findings.push(CheckFinding {
            id: "branch_context".to_string(),
            verdict: Verdict::Fail,
            message: format!(
                "Currently on branch '{}', expected 'develop'",
                snapshot.branch.as_deref().unwrap_or("HEAD")
            ),
        });
    }

    // 5. Version and tag consistency (no conflicting existing tags)
    findings.push(evaluate_tag_consistency(snapshot));

    // 6. Required external tools
    findings.push(CheckFinding {
        id: "required_tools".to_string(),
        verdict: Verdict::Pass,
        message: "Required tool 'git' is available and functional".to_string(),
    });

    findings
}

fn evaluate_tag_consistency(snapshot: &Snapshot) -> CheckFinding {
    let local_conflicts =
        crate::release::version::conflicting_tags(&snapshot.version, &snapshot.local_tags);

    if !local_conflicts.is_empty() {
        CheckFinding {
            id: "tag_consistency".to_string(),
            verdict: Verdict::Fail,
            message: format!(
                "Conflicting local tag(s) already exist for version {}: {}",
                snapshot.version,
                local_conflicts.join(", ")
            ),
        }
    } else if snapshot
        .latest_local_tag
        .as_ref()
        .is_some_and(|tag| *tag > snapshot.version)
    {
        CheckFinding {
            id: "tag_consistency".to_string(),
            verdict: Verdict::Fail,
            message: format!(
                "Cargo version {} is older than latest local tag {}",
                snapshot.version,
                snapshot
                    .latest_local_tag
                    .as_ref()
                    .map_or_else(String::new, ToString::to_string)
            ),
        }
    } else {
        CheckFinding {
            id: "tag_consistency".to_string(),
            verdict: Verdict::Pass,
            message: format!(
                "Version {} is consistent and tag does not exist locally",
                snapshot.version
            ),
        }
    }
}

fn evaluate_remote_invariants(snapshot: &Snapshot) -> Vec<CheckFinding> {
    vec![
        evaluate_upstream_sync(snapshot),
        evaluate_remote_tags(snapshot),
        evaluate_remote_ci(snapshot),
    ]
}

fn evaluate_remote_tags(snapshot: &Snapshot) -> CheckFinding {
    if snapshot.remote_url.is_none() {
        CheckFinding {
            id: "remote_tag_consistency".to_string(),
            verdict: Verdict::Unknown,
            message: "Remote 'origin' is not configured; cannot verify remote tags".to_string(),
        }
    } else if let Some(err) = &snapshot.remote_tags_error {
        CheckFinding {
            id: "remote_tag_consistency".to_string(),
            verdict: Verdict::Unknown,
            message: format!("Remote tags unavailable: {err}"),
        }
    } else if let Some(remote_tags) = &snapshot.remote_tags {
        let remote_conflicts =
            crate::release::version::conflicting_tags(&snapshot.version, remote_tags);
        if !remote_conflicts.is_empty() {
            CheckFinding {
                id: "remote_tag_consistency".to_string(),
                verdict: Verdict::Fail,
                message: format!(
                    "Conflicting remote tag(s) already exist for version {}: {}",
                    snapshot.version,
                    remote_conflicts.join(", ")
                ),
            }
        } else if snapshot
            .latest_remote_tag
            .as_ref()
            .is_some_and(|tag| *tag > snapshot.version)
        {
            CheckFinding {
                id: "remote_tag_consistency".to_string(),
                verdict: Verdict::Fail,
                message: format!(
                    "Cargo version {} is older than latest remote tag {}",
                    snapshot.version,
                    snapshot
                        .latest_remote_tag
                        .as_ref()
                        .map_or_else(String::new, ToString::to_string)
                ),
            }
        } else {
            CheckFinding {
                id: "remote_tag_consistency".to_string(),
                verdict: Verdict::Pass,
                message: format!(
                    "No conflicting remote tag exists for version {}",
                    snapshot.version
                ),
            }
        }
    } else {
        CheckFinding {
            id: "remote_tag_consistency".to_string(),
            verdict: Verdict::Unknown,
            message: "Remote tag evidence is not available".to_string(),
        }
    }
}

fn evaluate_upstream_sync(snapshot: &Snapshot) -> CheckFinding {
    if snapshot.remote_url.is_none() {
        CheckFinding {
            id: "branch_upstream_sync".to_string(),
            verdict: Verdict::Unknown,
            message: "Remote 'origin' is not configured; cannot verify upstream branch sync"
                .to_string(),
        }
    } else if let Some(ab) = snapshot.branch_relationships.current_vs_upstream {
        if ab.behind > 0 {
            CheckFinding {
                id: "branch_upstream_sync".to_string(),
                verdict: Verdict::Fail,
                message: format!(
                    "Branch is behind upstream by {} commit(s); pull/rebase required",
                    ab.behind
                ),
            }
        } else if ab.ahead > 0 {
            CheckFinding {
                id: "branch_upstream_sync".to_string(),
                verdict: Verdict::Fail,
                message: format!(
                    "Branch has {} unpushed commit(s); CI must validate pushed commits",
                    ab.ahead
                ),
            }
        } else {
            CheckFinding {
                id: "branch_upstream_sync".to_string(),
                verdict: Verdict::Pass,
                message: "Current branch is in sync with upstream tracking branch".to_string(),
            }
        }
    } else {
        CheckFinding {
            id: "branch_upstream_sync".to_string(),
            verdict: Verdict::Unknown,
            message: "Upstream tracking branch is not configured; cannot verify remote sync"
                .to_string(),
        }
    }
}

fn evaluate_remote_ci(snapshot: &Snapshot) -> CheckFinding {
    if snapshot.actions.is_none() || snapshot.actions_error.is_some() {
        let err_msg = snapshot
            .actions_error
            .as_deref()
            .unwrap_or("GitHub Actions evidence unavailable (CLI unauthenticated or offline)");
        CheckFinding {
            id: "remote_ci_exact_sha".to_string(),
            verdict: Verdict::Unknown,
            message: format!("Remote CI status could not be established: {err_msg}"),
        }
    } else {
        let matching = snapshot.matching_actions();
        if matching.is_empty() {
            CheckFinding {
                id: "remote_ci_exact_sha".to_string(),
                verdict: Verdict::Fail,
                message: format!(
                    "No GitHub Actions workflow runs found for exact commit {}",
                    snapshot.commit
                ),
            }
        } else {
            let has_pending = matching.iter().any(|r| r.status != "completed");
            let has_failure = matching
                .iter()
                .any(|r| r.conclusion.as_deref() != Some("success"));

            if has_pending {
                CheckFinding {
                    id: "remote_ci_exact_sha".to_string(),
                    verdict: Verdict::Unknown,
                    message: format!(
                        "GitHub Actions workflow run for commit {} is still in progress",
                        snapshot.commit
                    ),
                }
            } else if has_failure {
                CheckFinding {
                    id: "remote_ci_exact_sha".to_string(),
                    verdict: Verdict::Fail,
                    message: format!(
                        "GitHub Actions workflow run for commit {} did not succeed",
                        snapshot.commit
                    ),
                }
            } else {
                CheckFinding {
                    id: "remote_ci_exact_sha".to_string(),
                    verdict: Verdict::Pass,
                    message: format!(
                        "Exact commit {} validated by {} successful GitHub Actions run(s)",
                        snapshot.commit,
                        matching.len()
                    ),
                }
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod tests {
    use super::*;
    use crate::repository::{AheadBehind, BranchRelationships, WorkflowRun};
    use semver::Version;
    use std::path::PathBuf;

    fn base_snapshot() -> Snapshot {
        Snapshot {
            root: PathBuf::from("/repo"),
            remote_url: Some("https://github.com/example/repo".into()),
            branch: Some("develop".into()),
            commit: "1111111111111111111111111111111111111111".into(),
            clean: true,
            version: Version::new(0, 2, 0),
            latest_local_tag: Some(Version::new(0, 1, 0)),
            local_tags: vec!["0.1.0".into()],
            latest_remote_tag: Some(Version::new(0, 1, 0)),
            remote_tags: Some(vec!["0.1.0".into()]),
            remote_tags_error: None,
            branch_relationships: BranchRelationships {
                current_branch: Some("develop".into()),
                is_detached: false,
                is_on_develop: true,
                current_vs_upstream: Some(AheadBehind {
                    ahead: 0,
                    behind: 0,
                }),
                develop_vs_main: Some(AheadBehind {
                    ahead: 1,
                    behind: 0,
                }),
            },
            actions: None,
            actions_error: None,
            warnings: Vec::new(),
        }
    }

    #[test]
    fn local_only_passes_clean_develop() {
        let snapshot = base_snapshot();
        let report = CheckReport::evaluate(&snapshot, true);
        assert!(report.eligible);
        assert_eq!(report.summary.fail, 0);
        assert_eq!(report.summary.unknown, 0);
    }

    #[test]
    fn fails_on_dirty_working_tree() {
        let mut snapshot = base_snapshot();
        snapshot.clean = false;
        let report = CheckReport::evaluate(&snapshot, true);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "clean_working_tree" && f.verdict == Verdict::Fail)
        );
    }

    #[test]
    fn fails_on_detached_head() {
        let mut snapshot = base_snapshot();
        snapshot.branch = None;
        snapshot.branch_relationships.is_detached = true;
        snapshot.branch_relationships.is_on_develop = false;
        let report = CheckReport::evaluate(&snapshot, true);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "branch_context" && f.verdict == Verdict::Fail)
        );
    }

    #[test]
    fn fails_on_wrong_branch() {
        let mut snapshot = base_snapshot();
        snapshot.branch = Some("feature/foo".into());
        snapshot.branch_relationships.is_on_develop = false;
        let report = CheckReport::evaluate(&snapshot, true);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "branch_context" && f.verdict == Verdict::Fail)
        );
    }

    #[test]
    fn fails_on_tag_conflict() {
        let mut snapshot = base_snapshot();
        snapshot.local_tags.push("0.2.0".into());
        let report = CheckReport::evaluate(&snapshot, true);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "tag_consistency" && f.verdict == Verdict::Fail)
        );
    }

    #[test]
    fn fails_closed_when_remote_evidence_missing() {
        let snapshot = base_snapshot();
        // local_only is false, but actions is None
        let report = CheckReport::evaluate(&snapshot, false);
        assert!(!report.eligible);
        assert_eq!(report.summary.unknown, 1);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "remote_ci_exact_sha" && f.verdict == Verdict::Unknown)
        );
    }

    #[test]
    fn passes_when_remote_ci_exact_sha_succeeds() {
        let mut snapshot = base_snapshot();
        snapshot.actions = Some(vec![WorkflowRun {
            name: "CI".into(),
            head_branch: "develop".into(),
            head_sha: "1111111111111111111111111111111111111111".into(),
            status: "completed".into(),
            conclusion: Some("success".into()),
            url: "https://github.com/example/repo/actions/runs/1".into(),
        }]);
        let report = CheckReport::evaluate(&snapshot, false);
        assert!(report.eligible);
        assert_eq!(report.summary.fail, 0);
        assert_eq!(report.summary.unknown, 0);
    }

    #[test]
    fn fails_when_ci_matches_different_sha() {
        let mut snapshot = base_snapshot();
        snapshot.actions = Some(vec![WorkflowRun {
            name: "CI".into(),
            head_branch: "develop".into(),
            head_sha: "9999999999999999999999999999999999999999".into(),
            status: "completed".into(),
            conclusion: Some("success".into()),
            url: "https://github.com/example/repo/actions/runs/1".into(),
        }]);
        let report = CheckReport::evaluate(&snapshot, false);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "remote_ci_exact_sha" && f.verdict == Verdict::Fail)
        );
    }

    #[test]
    fn fails_closed_when_remote_tags_unavailable() {
        let mut snapshot = base_snapshot();
        snapshot.remote_tags = None;
        snapshot.remote_tags_error = Some("network unreachable".into());
        let report = CheckReport::evaluate(&snapshot, false);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "remote_tag_consistency" && f.verdict == Verdict::Unknown)
        );
    }

    #[test]
    fn pending_ci_classified_as_unknown() {
        let mut snapshot = base_snapshot();
        snapshot.actions = Some(vec![WorkflowRun {
            name: "CI".into(),
            head_branch: "develop".into(),
            head_sha: "1111111111111111111111111111111111111111".into(),
            status: "in_progress".into(),
            conclusion: None,
            url: "https://github.com/example/repo/actions/runs/1".into(),
        }]);
        let report = CheckReport::evaluate(&snapshot, false);
        assert!(!report.eligible);
        assert!(
            report
                .findings
                .iter()
                .any(|f| f.id == "remote_ci_exact_sha" && f.verdict == Verdict::Unknown)
        );
    }
}
