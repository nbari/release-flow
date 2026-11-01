use anyhow::{Result, bail};
use semver::Version;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Bump {
    Patch,
    Minor,
    Major,
}

impl Bump {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Patch => "patch",
            Self::Minor => "minor",
            Self::Major => "major",
        }
    }
}

/// Compute the next stable version without touching Cargo.toml or Git.
///
/// # Errors
///
/// Returns an error if the version contains prerelease/build metadata or arithmetic overflows.
pub fn next(current: &Version, bump: Bump) -> Result<Version> {
    if !current.pre.is_empty() || !current.build.is_empty() {
        bail!("planning a bump from a prerelease/build version is not yet supported");
    }
    let (major, minor, patch) = match bump {
        Bump::Patch => (
            current.major,
            current.minor,
            checked_increment(current.patch)?,
        ),
        Bump::Minor => (current.major, checked_increment(current.minor)?, 0),
        Bump::Major => (checked_increment(current.major)?, 0, 0),
    };
    Ok(Version::new(major, minor, patch))
}

fn checked_increment(value: u64) -> Result<u64> {
    value
        .checked_add(1)
        .ok_or_else(|| anyhow::anyhow!("version component overflow"))
}

/// Parse a tag string that may optionally have a leading 'v'.
#[must_use]
pub fn parse_tag(tag: &str) -> Option<Version> {
    let trimmed = tag.trim();
    let candidate = trimmed.strip_prefix('v').unwrap_or(trimmed);
    Version::parse(candidate).ok()
}

/// Ignore unrelated Git tags; only stable X.Y.Z or vX.Y.Z tags are release identifiers.
#[must_use]
pub fn latest_tag(tags: &str) -> Option<Version> {
    tags.lines()
        .filter_map(parse_tag)
        .filter(|version| version.pre.is_empty() && version.build.is_empty())
        .max()
}

/// Compute latest tag from a slice of tag strings.
#[must_use]
pub fn latest_tag_from_slice(tags: &[String]) -> Option<Version> {
    tags.iter()
        .map(String::as_str)
        .filter_map(parse_tag)
        .filter(|version| version.pre.is_empty() && version.build.is_empty())
        .max()
}

/// Find tags in `tags` that conflict with `version` (either `X.Y.Z` or `vX.Y.Z`).
#[must_use]
pub fn conflicting_tags<'a>(version: &Version, tags: &'a [String]) -> Vec<&'a str> {
    let exact = version.to_string();
    let prefixed = format!("v{version}");
    tags.iter()
        .filter(|&tag| {
            let trimmed = tag.trim();
            trimmed == exact || trimmed == prefixed
        })
        .map(String::as_str)
        .collect()
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used, clippy::assert_is_empty)]
mod tests {
    use super::{Bump, latest_tag, next};
    use semver::Version;

    #[test]
    fn bumps_all_stable_components() {
        let current = Version::new(0, 1, 9);
        assert_eq!(
            next(&current, Bump::Patch).expect("patch"),
            Version::new(0, 1, 10)
        );
        assert_eq!(
            next(&current, Bump::Minor).expect("minor"),
            Version::new(0, 2, 0)
        );
        assert_eq!(
            next(&current, Bump::Major).expect("major"),
            Version::new(1, 0, 0)
        );
    }

    #[test]
    fn tags_use_semantic_numeric_order() {
        let tags = "test\n0.1.9\n0.1.10\nv0.9.0\n0.2.0-rc.1\n";
        assert_eq!(latest_tag(tags), Some(Version::new(0, 9, 0)));
    }

    #[test]
    fn detects_conflicting_tags() {
        let tags = vec![
            "0.1.0".to_string(),
            "v0.2.0".to_string(),
            "unrelated".to_string(),
        ];
        let v1 = Version::new(0, 1, 0);
        let conflicts1 = super::conflicting_tags(&v1, &tags);
        assert_eq!(conflicts1, vec!["0.1.0"]);

        let v2 = Version::new(0, 2, 0);
        let conflicts2 = super::conflicting_tags(&v2, &tags);
        assert_eq!(conflicts2, vec!["v0.2.0"]);

        let v3 = Version::new(0, 3, 0);
        assert!(super::conflicting_tags(&v3, &tags).is_empty());
    }
    #[test]
    fn reject_prerelease_bump() {
        let current = Version::parse("1.0.0-rc.1").expect("semver");
        assert!(next(&current, Bump::Patch).is_err());
    }

    #[test]
    fn checked_overflow() {
        assert!(next(&Version::new(u64::MAX, 0, 0), Bump::Major).is_err());
    }
}
