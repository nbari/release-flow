use anyhow::{Context, Result, anyhow, ensure};
use semver::Version;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

/// Trait to execute external commands; allows mocking in tests.
pub trait CommandRunner: Send + Sync {
    /// # Errors
    /// Returns an error if running the command fails or exits with a non-zero status.
    fn run(&self, program: &str, args: &[&str], cwd: Option<&Path>) -> Result<String>;
}

/// Default OS command runner.
#[derive(Debug, Default, Clone, Copy)]
pub struct OsCommandRunner;

impl CommandRunner for OsCommandRunner {
    fn run(&self, program: &str, args: &[&str], cwd: Option<&Path>) -> Result<String> {
        let mut process = Command::new(program);
        process.args(args);
        if program == "gh" {
            process.env("GH_PROMPT_DISABLED", "1");
        } else if program == "git" {
            process.env("GIT_TERMINAL_PROMPT", "0");
            process.env("GIT_SSH_COMMAND", "ssh -oBatchMode=yes");
        }
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
}

/// Ahead and behind commit counts between two references.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct AheadBehind {
    pub ahead: usize,
    pub behind: usize,
}

/// Relationships between branches (e.g. current vs upstream, develop vs main).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct BranchRelationships {
    pub current_branch: Option<String>,
    pub is_detached: bool,
    pub is_on_develop: bool,
    pub current_vs_upstream: Option<AheadBehind>,
    pub develop_vs_main: Option<AheadBehind>,
}

/// A GitHub Actions workflow run.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WorkflowRun {
    pub name: String,
    #[serde(rename = "head_branch", alias = "headBranch")]
    pub head_branch: Option<String>,
    #[serde(rename = "head_sha", alias = "headSha")]
    pub head_sha: String,
    pub status: String,
    pub conclusion: Option<String>,
    pub url: String,
}

/// Read-only snapshot of the repository state and optional GitHub Actions.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Snapshot {
    pub root: PathBuf,
    pub remote_url: Option<String>,
    pub branch: Option<String>,
    pub commit: String,
    pub clean: bool,
    pub version: Version,
    pub latest_local_tag: Option<Version>,
    pub local_tags: Vec<String>,
    pub latest_remote_tag: Option<Version>,
    pub remote_tags: Option<Vec<String>>,
    pub remote_tags_error: Option<String>,
    pub branch_relationships: BranchRelationships,
    pub actions: Option<Vec<WorkflowRun>>,
    pub actions_error: Option<String>,
    pub warnings: Vec<String>,
}

impl Snapshot {
    /// Inspect the local repository using standard OS commands.
    ///
    /// # Errors
    /// Returns an error if Git repository inspection fails or the Cargo manifest cannot be parsed.
    pub fn inspect() -> Result<Self> {
        Self::inspect_internal(&OsCommandRunner, None, true)
    }

    /// Inspect the local repository without network queries (skipping remote tag inspection).
    ///
    /// # Errors
    /// Returns an error if Git repository inspection fails or the Cargo manifest cannot be parsed.
    pub fn inspect_local() -> Result<Self> {
        Self::inspect_internal(&OsCommandRunner, None, false)
    }

    /// Inspect repository using a specified command runner and optional base directory.
    ///
    /// # Errors
    /// Returns an error if Git repository inspection fails or the Cargo manifest cannot be parsed.
    pub fn inspect_with(runner: &dyn CommandRunner, cwd: Option<&Path>) -> Result<Self> {
        Self::inspect_internal(runner, cwd, true)
    }

    /// Internal repository inspection implementation.
    ///
    /// # Errors
    /// Returns an error if Git repository inspection fails or the Cargo manifest cannot be parsed.
    pub fn inspect_internal(
        runner: &dyn CommandRunner,
        cwd: Option<&Path>,
        include_remote: bool,
    ) -> Result<Self> {
        let root = PathBuf::from(runner.run("git", &["rev-parse", "--show-toplevel"], cwd)?);
        let commit = runner.run("git", &["rev-parse", "HEAD"], Some(&root))?;
        let clean = runner
            .run("git", &["status", "--porcelain"], Some(&root))?
            .is_empty();
        let version = read_version(&root.join("Cargo.toml"))?;

        let branch_raw = runner
            .run("git", &["branch", "--show-current"], Some(&root))
            .unwrap_or_default();
        let branch = if branch_raw.is_empty() {
            None
        } else {
            Some(branch_raw)
        };
        let is_detached = branch.is_none();
        let is_on_develop = branch.as_deref() == Some("develop");

        let remote_url = runner
            .run("git", &["remote", "get-url", "origin"], Some(&root))
            .ok();

        let local_tags_raw = runner
            .run("git", &["tag", "--list"], Some(&root))
            .unwrap_or_default();
        let local_tags: Vec<String> = local_tags_raw
            .lines()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned)
            .collect();
        let latest_local_tag = crate::release::version::latest_tag_from_slice(&local_tags);

        let (remote_tags, latest_remote_tag, remote_tags_error) = if include_remote {
            inspect_remote_tags(runner, &root, remote_url.is_some())
        } else {
            (None, None, None)
        };

        let branch_relationships =
            inspect_branch_relationships(runner, &root, branch.as_deref(), is_detached);

        let mut warnings = Vec::new();
        if !clean {
            warnings.push("working tree has uncommitted changes".to_string());
        }
        if is_detached {
            warnings.push("detached HEAD state; not on any branch".to_string());
        } else if !is_on_develop {
            warnings.push(format!(
                "on branch '{}', expected 'develop' for release integration",
                branch.as_deref().unwrap_or("HEAD")
            ));
        }

        if let Some(err) = &remote_tags_error {
            warnings.push(format!("remote tags unavailable: {err}"));
        }

        if let Some(ab) = branch_relationships.current_vs_upstream {
            if ab.behind > 0 {
                warnings.push(format!(
                    "current branch is behind upstream by {} commit(s)",
                    ab.behind
                ));
            }
            if ab.ahead > 0 {
                warnings.push(format!(
                    "current branch has {} unpushed commit(s)",
                    ab.ahead
                ));
            }
        }

        if let Some(ab) = branch_relationships
            .develop_vs_main
            .filter(|ab| ab.behind > 0)
        {
            warnings.push(format!(
                "main has {} commit(s) not present in develop",
                ab.behind
            ));
        }

        Ok(Self {
            root,
            remote_url,
            branch,
            commit,
            clean,
            version,
            latest_local_tag,
            local_tags,
            latest_remote_tag,
            remote_tags,
            remote_tags_error,
            branch_relationships,
            actions: None,
            actions_error: None,
            warnings,
        })
    }

    /// Add GitHub Actions information using standard OS runner.
    #[must_use]
    pub fn with_actions(self) -> Self {
        self.with_actions_runner(&OsCommandRunner)
    }

    /// Add GitHub Actions information using the specified runner.
    #[must_use]
    pub fn with_actions_runner(mut self, runner: &dyn CommandRunner) -> Self {
        let (actions, error) = query_actions(&self.root, runner);
        if let Some(err) = &error {
            self.warnings
                .push(format!("GitHub Actions unavailable: {err}"));
        } else if let Some(runs) = &actions {
            let matching: Vec<&WorkflowRun> =
                runs.iter().filter(|r| r.head_sha == self.commit).collect();
            if matching.is_empty() {
                self.warnings.push(format!(
                    "no GitHub Actions runs found for exact commit {}",
                    self.commit
                ));
            } else {
                for run in &matching {
                    if run.status != "completed" || run.conclusion.as_deref() != Some("success") {
                        self.warnings.push(format!(
                            "GitHub Actions run '{}' on {} status is {} (conclusion: {:?})",
                            run.name, self.commit, run.status, run.conclusion
                        ));
                    }
                }
            }
        }
        self.actions = actions;
        self.actions_error = error;
        self
    }

    /// Return all workflow runs matching the current commit SHA.
    #[must_use]
    pub fn matching_actions(&self) -> Vec<&WorkflowRun> {
        self.actions
            .as_deref()
            .unwrap_or_default()
            .iter()
            .filter(|r| r.head_sha == self.commit)
            .collect()
    }
}

fn inspect_remote_tags(
    runner: &dyn CommandRunner,
    root: &Path,
    has_remote: bool,
) -> (Option<Vec<String>>, Option<Version>, Option<String>) {
    if !has_remote {
        return (
            None,
            None,
            Some("remote 'origin' is not configured".to_string()),
        );
    }
    match runner.run(
        "git",
        &["ls-remote", "--tags", "--refs", "origin"],
        Some(root),
    ) {
        Ok(output) => {
            let tags: Vec<String> = output
                .lines()
                .filter_map(|line| {
                    let mut parts = line.split_whitespace();
                    let _sha = parts.next()?;
                    let ref_name = parts.next()?;
                    ref_name.strip_prefix("refs/tags/").map(ToOwned::to_owned)
                })
                .collect();
            let latest = crate::release::version::latest_tag_from_slice(&tags);
            (Some(tags), latest, None)
        }
        Err(error) => (None, None, Some(error.to_string())),
    }
}

fn parse_ahead_behind(output: &str) -> Option<AheadBehind> {
    let mut parts = output.split_whitespace();
    let behind = parts.next()?.parse::<usize>().ok()?;
    let ahead = parts.next()?.parse::<usize>().ok()?;
    Some(AheadBehind { ahead, behind })
}

fn ref_exists(runner: &dyn CommandRunner, root: &Path, git_ref: &str) -> bool {
    runner
        .run(
            "git",
            &["rev-parse", "--verify", "--quiet", git_ref],
            Some(root),
        )
        .is_ok()
}

fn inspect_branch_relationships(
    runner: &dyn CommandRunner,
    root: &Path,
    current_branch: Option<&str>,
    is_detached: bool,
) -> BranchRelationships {
    let is_on_develop = current_branch == Some("develop");

    let current_vs_upstream = if is_detached {
        None
    } else {
        runner
            .run(
                "git",
                &["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"],
                Some(root),
            )
            .ok()
            .and_then(|upstream| {
                let range = format!("{upstream}...HEAD");
                runner
                    .run(
                        "git",
                        &["rev-list", "--left-right", "--count", &range],
                        Some(root),
                    )
                    .ok()
            })
            .as_deref()
            .and_then(parse_ahead_behind)
    };

    let develop_vs_main = {
        let local_refs = ref_exists(runner, root, "refs/heads/main")
            && ref_exists(runner, root, "refs/heads/develop");
        let remote_refs = ref_exists(runner, root, "refs/remotes/origin/main")
            && ref_exists(runner, root, "refs/remotes/origin/develop");

        let range = if local_refs {
            Some("refs/heads/main...refs/heads/develop")
        } else if remote_refs {
            Some("refs/remotes/origin/main...refs/remotes/origin/develop")
        } else {
            None
        };

        range.and_then(|r| {
            runner
                .run(
                    "git",
                    &["rev-list", "--left-right", "--count", r],
                    Some(root),
                )
                .ok()
                .as_deref()
                .and_then(parse_ahead_behind)
        })
    };

    BranchRelationships {
        current_branch: current_branch.map(ToOwned::to_owned),
        is_detached,
        is_on_develop,
        current_vs_upstream,
        develop_vs_main,
    }
}

/// A Rust workspace may declare its version at either package or workspace level.
///
/// # Errors
/// Returns an error if the manifest cannot be read or lacks a valid version.
pub fn read_version(path: &Path) -> Result<Version> {
    let manifest = fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let value: toml::Value =
        toml::from_str(&manifest).with_context(|| format!("parse {}", path.display()))?;
    let version = value
        .get("package")
        .and_then(|package| package.get("version"))
        .and_then(toml::Value::as_str)
        .or_else(|| {
            value
                .get("workspace")
                .and_then(|workspace| workspace.get("package"))
                .and_then(|package| package.get("version"))
                .and_then(toml::Value::as_str)
        })
        .ok_or_else(|| anyhow!("missing package.version or workspace.package.version"))?;
    Version::parse(version).with_context(|| format!("parse version {version}"))
}

fn query_actions(
    root: &Path,
    runner: &dyn CommandRunner,
) -> (Option<Vec<WorkflowRun>>, Option<String>) {
    let output = runner.run(
        "gh",
        &[
            "run",
            "list",
            "--limit",
            "10",
            "--json",
            "name,headBranch,headSha,status,conclusion,url",
        ],
        Some(root),
    );
    match output {
        Err(error) => (None, Some(error.to_string())),
        Ok(json_text) => match serde_json::from_str::<Vec<WorkflowRun>>(&json_text) {
            Ok(runs) => (Some(runs), None),
            Err(error) => (
                None,
                Some(format!("invalid GitHub Actions response: {error}")),
            ),
        },
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
mod tests {
    use super::*;
    use std::{collections::HashMap, sync::Mutex};

    #[test]
    fn reads_package_version() {
        let path = temporary_manifest("[package]\nname = \"sample\"\nversion = \"0.2.3\"\n");
        assert_eq!(read_version(&path).expect("manifest").to_string(), "0.2.3");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn reads_workspace_version() {
        let path = temporary_manifest("[workspace.package]\nversion = \"1.2.3\"\n");
        assert_eq!(read_version(&path).expect("manifest").to_string(), "1.2.3");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn parses_ahead_behind_output() {
        assert_eq!(
            parse_ahead_behind("3\t5"),
            Some(AheadBehind {
                ahead: 5,
                behind: 3
            })
        );
        assert_eq!(
            parse_ahead_behind("0 0"),
            Some(AheadBehind {
                ahead: 0,
                behind: 0
            })
        );
        assert_eq!(parse_ahead_behind("invalid"), None);
    }

    struct MockRunner {
        responses: Mutex<HashMap<String, Result<String>>>,
    }

    impl MockRunner {
        fn new() -> Self {
            Self {
                responses: Mutex::new(HashMap::new()),
            }
        }

        fn set(&self, key: &str, result: Result<String>) {
            self.responses
                .lock()
                .unwrap()
                .insert(key.to_string(), result);
        }
    }

    impl CommandRunner for MockRunner {
        fn run(&self, program: &str, args: &[&str], _cwd: Option<&Path>) -> Result<String> {
            let key = format!("{program} {}", args.join(" "));
            if let Some(res) = self.responses.lock().unwrap().get(&key) {
                return match res {
                    Ok(val) => Ok(val.clone()),
                    Err(err) => Err(anyhow!("{err}")),
                };
            }
            Err(anyhow!("unmocked command: {key}"))
        }
    }

    #[test]
    fn mock_inspect_develop_clean() {
        let manifest_dir = std::env::temp_dir().join(format!("rf-test-{}", std::process::id()));
        fs::create_dir_all(&manifest_dir).unwrap();
        let manifest_path = manifest_dir.join("Cargo.toml");
        fs::write(
            &manifest_path,
            "[package]\nname = \"test\"\nversion = \"1.0.0\"\n",
        )
        .unwrap();

        let runner = MockRunner::new();
        runner.set(
            "git rev-parse --show-toplevel",
            Ok(manifest_dir.display().to_string()),
        );
        runner.set(
            "git rev-parse HEAD",
            Ok("abcdef1234567890abcdef1234567890abcdef12".into()),
        );
        runner.set("git status --porcelain", Ok(String::new()));
        runner.set("git branch --show-current", Ok("develop".into()));
        runner.set(
            "git remote get-url origin",
            Ok("https://github.com/example/repo".into()),
        );
        runner.set("git tag --list", Ok("0.9.0\n0.9.1\n".into()));
        runner.set(
            "git ls-remote --tags --refs origin",
            Ok("111 refs/tags/0.9.0\n222 refs/tags/0.9.1\n".into()),
        );
        runner.set(
            "git rev-parse --abbrev-ref --symbolic-full-name @{u}",
            Ok("origin/develop".into()),
        );
        runner.set(
            "git rev-list --left-right --count origin/develop...HEAD",
            Ok("0\t0".into()),
        );
        runner.set(
            "git rev-parse --verify --quiet refs/heads/main",
            Ok("main-sha".into()),
        );
        runner.set(
            "git rev-parse --verify --quiet refs/heads/develop",
            Ok("dev-sha".into()),
        );
        runner.set(
            "git rev-list --left-right --count refs/heads/main...refs/heads/develop",
            Ok("0\t2".into()),
        );

        let snapshot = Snapshot::inspect_with(&runner, None).expect("snapshot");
        assert_eq!(snapshot.branch.as_deref(), Some("develop"));
        assert!(snapshot.clean);
        assert_eq!(snapshot.version.to_string(), "1.0.0");
        assert_eq!(
            snapshot.latest_local_tag.map(|v| v.to_string()),
            Some("0.9.1".into())
        );
        assert_eq!(
            snapshot.latest_remote_tag.map(|v| v.to_string()),
            Some("0.9.1".into())
        );
        assert!(snapshot.branch_relationships.is_on_develop);
        assert!(!snapshot.branch_relationships.is_detached);
        assert_eq!(
            snapshot.branch_relationships.current_vs_upstream,
            Some(AheadBehind {
                ahead: 0,
                behind: 0
            })
        );
        assert_eq!(
            snapshot.branch_relationships.develop_vs_main,
            Some(AheadBehind {
                ahead: 2,
                behind: 0
            })
        );

        let _ = fs::remove_dir_all(manifest_dir);
    }

    #[test]
    fn mock_inspect_detached_head_dirty() {
        let manifest_dir = std::env::temp_dir().join(format!("rf-test-det-{}", std::process::id()));
        fs::create_dir_all(&manifest_dir).unwrap();
        let manifest_path = manifest_dir.join("Cargo.toml");
        fs::write(
            &manifest_path,
            "[package]\nname = \"test\"\nversion = \"1.0.0\"\n",
        )
        .unwrap();

        let runner = MockRunner::new();
        runner.set(
            "git rev-parse --show-toplevel",
            Ok(manifest_dir.display().to_string()),
        );
        runner.set(
            "git rev-parse HEAD",
            Ok("abcdef1234567890abcdef1234567890abcdef12".into()),
        );
        runner.set("git status --porcelain", Ok(" M src/lib.rs\n".into()));
        runner.set("git branch --show-current", Ok(String::new()));
        runner.set("git remote get-url origin", Err(anyhow!("no remote")));
        runner.set("git tag --list", Ok(String::new()));
        runner.set(
            "git rev-parse --verify --quiet refs/heads/main",
            Err(anyhow!("no main")),
        );
        runner.set(
            "git rev-parse --verify --quiet refs/remotes/origin/main",
            Err(anyhow!("no remote main")),
        );

        let snapshot = Snapshot::inspect_with(&runner, None).expect("snapshot");
        assert_eq!(snapshot.branch, None);
        assert!(!snapshot.clean);
        assert!(snapshot.branch_relationships.is_detached);
        assert!(!snapshot.branch_relationships.is_on_develop);
        assert!(
            snapshot
                .warnings
                .iter()
                .any(|w| w.contains("uncommitted changes"))
        );
        assert!(
            snapshot
                .warnings
                .iter()
                .any(|w| w.contains("detached HEAD"))
        );

        let _ = fs::remove_dir_all(manifest_dir);
    }

    fn temporary_manifest(contents: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "release-flow-manifest-{}-{:?}.toml",
            std::process::id(),
            std::thread::current().id(),
        ));
        let _ = fs::write(&path, contents);
        path
    }
}
