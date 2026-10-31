use crate::{
    release::version::{self, Bump},
    repository::Snapshot,
};
use anyhow::Result;
use semver::Version;
use serde::{Deserialize, Serialize};

/// Report of a version bump planning calculation.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlanReport {
    pub base_version: Version,
    pub bump: Bump,
    pub proposed_version: Version,
    pub proposed_tag: String,
    pub branch: Option<String>,
    pub commit: String,
    pub eligible_locally: bool,
    pub blockers: Vec<String>,
    pub tag_conflicts: Vec<String>,
    pub observations: Vec<String>,
    pub warnings: Vec<String>,
    pub note: String,
}

impl PlanReport {
    /// Calculate the release plan based on a repository snapshot and bump type.
    ///
    /// # Errors
    /// Returns an error if next version calculation fails (e.g. prerelease or overflow).
    pub fn create(snapshot: &Snapshot, bump: Bump) -> Result<Self> {
        let proposed = version::next(&snapshot.version, bump)?;
        let proposed_tag = proposed.to_string();
        let mut blockers = Vec::new();
        let mut observations = Vec::new();

        if snapshot.branch_relationships.is_detached {
            blockers
                .push("detached HEAD state; releases must originate from 'develop'".to_string());
        } else if snapshot.branch.as_deref() != Some("develop") {
            blockers.push(format!(
                "expected develop, currently on {}",
                snapshot.branch.as_deref().unwrap_or("HEAD")
            ));
        }

        if !snapshot.clean {
            blockers.push("working tree is dirty".to_string());
        }

        let mut all_conflicts = version::conflicting_tags(&proposed, &snapshot.local_tags);
        if let Some(remote_tags) = &snapshot.remote_tags {
            for tag in version::conflicting_tags(&proposed, remote_tags) {
                if !all_conflicts.contains(&tag) {
                    all_conflicts.push(tag);
                }
            }
        }
        let tag_conflicts: Vec<String> = all_conflicts.into_iter().map(ToOwned::to_owned).collect();
        if !tag_conflicts.is_empty() {
            blockers.push(format!(
                "proposed version tag already exists: {}",
                tag_conflicts.join(", ")
            ));
        }

        if let Some(latest) = &snapshot.latest_local_tag {
            if proposed <= *latest {
                blockers.push(format!(
                    "proposed version {proposed} is not newer than latest local tag {latest}"
                ));
            } else {
                observations.push(format!(
                    "proposed version {proposed} is strictly greater than latest local tag {latest}"
                ));
            }
        }

        if let Some(latest_remote) = &snapshot.latest_remote_tag {
            if proposed <= *latest_remote {
                blockers.push(format!(
                    "proposed version {proposed} is not newer than latest remote tag {latest_remote}"
                ));
            } else {
                observations.push(format!(
                    "proposed version {proposed} is strictly greater than latest remote tag {latest_remote}"
                ));
            }
        }

        let eligible_locally = blockers.is_empty();

        Ok(Self {
            base_version: snapshot.version.clone(),
            bump,
            proposed_version: proposed,
            proposed_tag,
            branch: snapshot.branch.clone(),
            commit: snapshot.commit.clone(),
            eligible_locally,
            blockers,
            tag_conflicts,
            observations,
            warnings: snapshot.warnings.clone(),
            note:
                "Read-only local preview; remote CI and promotion guards are evaluated by `check`"
                    .to_string(),
        })
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::assert_is_empty)]
mod tests {
    use super::*;
    use crate::repository::BranchRelationships;
    use std::path::PathBuf;

    fn sample_snapshot() -> Snapshot {
        Snapshot {
            root: PathBuf::from("/repo"),
            remote_url: Some("https://github.com/example/repo".into()),
            branch: Some("develop".into()),
            commit: "1111111111111111111111111111111111111111".into(),
            clean: true,
            version: Version::new(0, 1, 0),
            latest_local_tag: Some(Version::new(0, 1, 0)),
            local_tags: vec!["0.1.0".into()],
            latest_remote_tag: Some(Version::new(0, 1, 0)),
            remote_tags: Some(vec!["0.1.0".into()]),
            remote_tags_error: None,
            branch_relationships: BranchRelationships {
                current_branch: Some("develop".into()),
                is_detached: false,
                is_on_develop: true,
                current_vs_upstream: None,
                develop_vs_main: None,
            },
            actions: None,
            actions_error: None,
            warnings: Vec::new(),
        }
    }

    #[test]
    fn plans_minor_bump_clean() {
        let snapshot = sample_snapshot();
        let plan = PlanReport::create(&snapshot, Bump::Minor).expect("plan");
        assert_eq!(plan.proposed_version, Version::new(0, 2, 0));
        assert!(plan.eligible_locally);
        assert!(plan.blockers.is_empty());
        assert!(plan.tag_conflicts.is_empty());
    }

    #[test]
    fn plans_patch_bump_conflict() {
        let mut snapshot = sample_snapshot();
        snapshot.local_tags.push("0.1.1".into());
        let plan = PlanReport::create(&snapshot, Bump::Patch).expect("plan");
        assert_eq!(plan.proposed_version, Version::new(0, 1, 1));
        assert!(!plan.eligible_locally);
        assert!(plan.tag_conflicts.contains(&"0.1.1".to_string()));
        assert!(plan.blockers.iter().any(|b| b.contains("already exists")));
    }
}
