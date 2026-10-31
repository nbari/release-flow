use anyhow::{Context, Result, anyhow, ensure};
use semver::Version;
use serde_json::Value;
use std::{fs, path::{Path, PathBuf}, process::Command};

/// Read-only snapshot of the current checkout and, when available, GitHub Actions.
#[derive(Debug)]
pub struct Snapshot {
    pub root: PathBuf,
    pub branch: String,
    pub commit: String,
    pub clean: bool,
    pub version: Version,
    pub latest_tag: Option<Version>,
    pub actions: Option<Value>,
    pub actions_error: Option<String>,
}

impl Snapshot {
    pub fn inspect() -> Result<Self> {
        let root = PathBuf::from(command("git", &["rev-parse", "--show-toplevel"], None)?);
        let branch = command("git", &["branch", "--show-current"], Some(&root))?;
        let commit = command("git", &["rev-parse", "HEAD"], Some(&root))?;
        let clean = command("git", &["status", "--porcelain"], Some(&root))?.is_empty();
        let version = read_version(&root.join("Cargo.toml"))?;
        let tags = command("git", &["tag", "--list"], Some(&root))?;
        let latest_tag = crate::release::version::latest_tag(&tags);
        Ok(Self {
            root,
            branch,
            commit,
            clean,
            version,
            latest_tag,
            actions: None,
            actions_error: None,
        })
    }

    /// Add optional GitHub Actions data only when a caller explicitly requests it.
    #[must_use]
    pub fn with_actions(mut self) -> Self {
        (self.actions, self.actions_error) = query_actions(&self.root);
        self
    }
}

fn command(program: &str, args: &[&str], cwd: Option<&Path>) -> Result<String> {
    let mut process = Command::new(program);
    process.args(args);
    if let Some(cwd) = cwd {
        process.current_dir(cwd);
    }
    let output = process.output().with_context(|| format!("run {program}"))?;
    ensure!(
        output.status.success(),
        "{program} {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr).trim()
    );
    Ok(String::from_utf8(output.stdout)
        .with_context(|| format!("decode {program} stdout"))?
        .trim()
        .to_owned())
}

/// A Rust workspace may declare its version at either package or workspace level.
pub fn read_version(path: &Path) -> Result<Version> {
    let manifest = fs::read_to_string(path)
        .with_context(|| format!("read {}", path.display()))?;
    let value: toml::Value = toml::from_str(&manifest)
        .with_context(|| format!("parse {}", path.display()))?;
    let version = value.get("package")
        .and_then(|package| package.get("version"))
        .and_then(toml::Value::as_str)
        .or_else(|| value.get("workspace")
            .and_then(|workspace| workspace.get("package"))
            .and_then(|package| package.get("version"))
            .and_then(toml::Value::as_str))
        .ok_or_else(|| anyhow!("missing package.version or workspace.package.version"))?;
    Version::parse(version).with_context(|| format!("parse version {version}"))
}

fn query_actions(root: &Path) -> (Option<Value>, Option<String>) {
    let output = Command::new("gh")
        .current_dir(root)
        .env("GH_PROMPT_DISABLED", "1")
        .args([
            "run", "list", "--limit", "5", "--json",
            "name,headBranch,headSha,status,conclusion,url",
        ])
        .output();
    match output {
        Err(error) => (None, Some(format!("GitHub CLI unavailable: {error}"))),
        Ok(output) if !output.status.success() => (
            None,
            Some(format!("GitHub Actions unavailable: {}", String::from_utf8_lossy(&output.stderr).trim())),
        ),
        Ok(output) => match serde_json::from_slice(&output.stdout) {
            Ok(value) => (Some(value), None),
            Err(error) => (None, Some(format!("invalid GitHub Actions response: {error}"))),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::read_version;
    use std::{fs, path::PathBuf};

    #[test]
    fn reads_package_version() {
        let path = temporary_manifest("[package]\nname = \"sample\"\nversion = \"0.2.3\"\n");
        assert_eq!(read_version(&path).expect("manifest").to_string(), "0.2.3");
        fs::remove_file(path).expect("cleanup");
    }

    #[test]
    fn reads_workspace_version() {
        let path = temporary_manifest("[workspace.package]\nversion = \"1.2.3\"\n");
        assert_eq!(read_version(&path).expect("manifest").to_string(), "1.2.3");
        fs::remove_file(path).expect("cleanup");
    }

    fn temporary_manifest(contents: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "release-flow-manifest-{}-{:?}.toml",
            std::process::id(),
            std::thread::current().id(),
        ));
        fs::write(&path, contents).expect("fixture");
        path
    }
}
