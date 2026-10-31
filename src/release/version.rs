use anyhow::{Result, bail};
use semver::Version;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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
pub fn next(current: &Version, bump: Bump) -> Result<Version> {
    if !current.pre.is_empty() || !current.build.is_empty() {
        bail!("planning a bump from a prerelease/build version is not yet supported");
    }
    let (major, minor, patch) = match bump {
        Bump::Patch => (current.major, current.minor, checked_increment(current.patch)?),
        Bump::Minor => (current.major, checked_increment(current.minor)?, 0),
        Bump::Major => (checked_increment(current.major)?, 0, 0),
    };
    Ok(Version::new(major, minor, patch))
}

fn checked_increment(value: u64) -> Result<u64> {
    value.checked_add(1).ok_or_else(|| anyhow::anyhow!("version component overflow"))
}

/// Ignore unrelated Git tags; only stable X.Y.Z tags are release identifiers.
#[must_use]
pub fn latest_tag(tags: &str) -> Option<Version> {
    tags.lines()
        .filter_map(|tag| Version::parse(tag.trim()).ok())
        .filter(|version| version.pre.is_empty() && version.build.is_empty())
        .max()
}

#[cfg(test)]
mod tests {
    use super::{Bump, latest_tag, next};
    use semver::Version;

    #[test]
    fn bumps_all_stable_components() {
        let current = Version::new(0, 1, 9);
        assert_eq!(next(&current, Bump::Patch).expect("patch"), Version::new(0, 1, 10));
        assert_eq!(next(&current, Bump::Minor).expect("minor"), Version::new(0, 2, 0));
        assert_eq!(next(&current, Bump::Major).expect("major"), Version::new(1, 0, 0));
    }

    #[test]
    fn tags_use_semantic_numeric_order() {
        let tags = "test\n0.1.9\n0.1.10\nv0.9.0\n0.2.0-rc.1\n";
        assert_eq!(latest_tag(tags), Some(Version::new(0, 1, 10)));
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
