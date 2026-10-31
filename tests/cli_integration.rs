#![allow(clippy::indexing_slicing, clippy::expect_used, clippy::unwrap_used)]

use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
};

#[allow(clippy::expect_used, clippy::unwrap_used)]
struct TempRepo {
    path: PathBuf,
}

#[allow(clippy::expect_used, clippy::unwrap_used)]
impl TempRepo {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "rf-test-{}-{}-{}",
            name,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("create temp repo dir");

        let repo = Self { path };
        repo.git(&["init", "-b", "develop"]);
        repo.git(&["config", "user.name", "Test User"]);
        repo.git(&["config", "user.email", "test@example.com"]);
        repo.git(&["config", "commit.gpgsign", "false"]);
        repo.git(&["config", "tag.gpgSign", "false"]);
        repo.git(&["config", "tag.forceSignAnnotated", "false"]);

        let manifest = r#"[package]
name = "sample"
version = "0.1.0"
edition = "2024"
"#;
        fs::write(repo.path.join("Cargo.toml"), manifest).expect("write Cargo.toml");
        fs::write(repo.path.join(".gitignore"), "*.profraw\n").expect("write .gitignore");
        repo.git(&["add", "Cargo.toml", ".gitignore"]);
        repo.git(&["commit", "-m", "Initial commit"]);

        repo
    }

    fn git(&self, args: &[&str]) -> String {
        let output = Command::new("git")
            .current_dir(&self.path)
            .args(args)
            .output()
            .expect("execute git");
        assert!(
            output.status.success(),
            "git {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    #[allow(dead_code)]
    fn head_commit(&self) -> String {
        self.git(&["rev-parse", "HEAD"])
    }

    fn run_cli(&self, args: &[&str], extra_path: Option<&Path>) -> (bool, String, String) {
        let binary = env!("CARGO_BIN_EXE_release-flow");
        let mut cmd = Command::new(binary);
        cmd.current_dir(&self.path);
        cmd.args(args);

        if let Some(extra) = extra_path {
            let current_path = std::env::var_os("PATH").unwrap_or_default();
            let mut paths = vec![extra.to_path_buf()];
            paths.extend(std::env::split_paths(&current_path));
            if let Ok(new_path) = std::env::join_paths(paths) {
                cmd.env("PATH", new_path);
            }
        }

        let output = cmd.output().expect("execute release-flow binary");
        (
            output.status.success(),
            String::from_utf8_lossy(&output.stdout).to_string(),
            String::from_utf8_lossy(&output.stderr).to_string(),
        )
    }
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_status_human_and_json() {
    let repo = TempRepo::new("status");

    let (success, stdout, _) = repo.run_cli(&["status"], None);
    assert!(success);
    assert!(stdout.contains("develop"));
    assert!(stdout.contains("clean"));
    assert!(stdout.contains("0.1.0"));

    let (success, stdout_json, _) = repo.run_cli(&["status", "--json"], None);
    assert!(success);
    let parsed: Value = serde_json::from_str(&stdout_json).expect("valid status json");
    assert_eq!(parsed["branch"], "develop");
    assert_eq!(parsed["clean"], true);
    assert_eq!(parsed["version"], "0.1.0");
    assert_eq!(parsed["branch_relationships"]["is_on_develop"], true);
    assert_eq!(parsed["branch_relationships"]["is_detached"], false);
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_plan_bump_variants_and_json() {
    let repo = TempRepo::new("plan");

    let (success, stdout_patch, _) = repo.run_cli(&["plan", "patch", "--json"], None);
    assert!(success);
    let patch: Value = serde_json::from_str(&stdout_patch).expect("valid patch json");
    assert_eq!(patch["base_version"], "0.1.0");
    assert_eq!(patch["proposed_version"], "0.1.1");
    assert_eq!(patch["eligible_locally"], true);

    let (success, stdout_minor, _) = repo.run_cli(&["plan", "minor", "--json"], None);
    assert!(success);
    let minor: Value = serde_json::from_str(&stdout_minor).expect("valid minor json");
    assert_eq!(minor["proposed_version"], "0.2.0");
    assert_eq!(minor["eligible_locally"], true);

    let (success, stdout_major, _) = repo.run_cli(&["plan", "major", "--json"], None);
    assert!(success);
    let major: Value = serde_json::from_str(&stdout_major).expect("valid major json");
    assert_eq!(major["proposed_version"], "1.0.0");
    assert_eq!(major["eligible_locally"], true);
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_check_local_only() {
    let repo = TempRepo::new("check-local");

    let (success, stdout, _) = repo.run_cli(&["check", "--local-only"], None);
    assert!(success);
    assert!(stdout.contains("ELIGIBLE FOR RELEASE"));
    assert!(stdout.contains("[PASS]"));

    let (success, stdout_json, _) = repo.run_cli(&["check", "--local-only", "--json"], None);
    assert!(success);
    let report: Value = serde_json::from_str(&stdout_json).expect("valid check json");
    assert_eq!(report["eligible"], true);
    assert_eq!(report["summary"]["fail"], 0);
    assert_eq!(report["summary"]["unknown"], 0);
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_check_fails_closed_when_remote_missing() {
    let repo = TempRepo::new("check-fail-closed");

    // Without --local-only, remote information cannot be verified, so it must fail closed
    let (success, stdout, _) = repo.run_cli(&["check"], None);
    assert!(!success);
    assert!(stdout.contains("BLOCKED (release gate failed closed)"));
    assert!(stdout.contains("[UNKNOWN]"));

    let (success, stdout_json, _) = repo.run_cli(&["check", "--json"], None);
    assert!(!success);
    let report: Value = serde_json::from_str(&stdout_json).expect("valid check json");
    assert_eq!(report["eligible"], false);
    assert!(report["summary"]["unknown"].as_u64().unwrap_or(0) > 0);
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_dirty_repository_detection() {
    let repo = TempRepo::new("dirty");

    fs::write(repo.path.join("untracked.txt"), "dirty contents").expect("write untracked");

    let (success, stdout, _) = repo.run_cli(&["status"], None);
    assert!(success);
    assert!(stdout.contains("dirty"));

    let (success, stdout, _) = repo.run_cli(&["plan", "patch"], None);
    assert!(success);
    assert!(stdout.contains("working tree is dirty"));

    let (success, stdout, _) = repo.run_cli(&["check", "--local-only"], None);
    assert!(!success);
    assert!(stdout.contains("[FAIL]"));
    assert!(stdout.contains("clean_working_tree"));
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_detached_head_detection() {
    let repo = TempRepo::new("detached");

    repo.git(&["checkout", "--detach"]);

    let (success, stdout, _) = repo.run_cli(&["status"], None);
    assert!(success);
    assert!(stdout.contains("HEAD (detached)"));

    let (success, stdout, _) = repo.run_cli(&["plan", "minor"], None);
    assert!(success);
    assert!(stdout.contains("detached HEAD state"));

    let (success, stdout, _) = repo.run_cli(&["check", "--local-only"], None);
    assert!(!success);
    assert!(stdout.contains("branch_context"));
    assert!(stdout.contains("[FAIL]"));
}

#[test]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_tag_conflicts_detection() {
    let repo = TempRepo::new("tag-conflicts");

    // Tag 0.2.0 already exists
    repo.git(&["tag", "-a", "0.2.0", "-m", "release 0.2.0"]);

    let (success, stdout_plan, _) = repo.run_cli(&["plan", "minor", "--json"], None);
    assert!(success);
    let plan: Value = serde_json::from_str(&stdout_plan).expect("plan json");
    assert_eq!(plan["eligible_locally"], false);
    assert!(plan["tag_conflicts"].to_string().contains("0.2.0"));

    // Also tag 0.1.0 (current version)
    repo.git(&["tag", "-a", "0.1.0", "-m", "release 0.1.0"]);
    let (success, stdout_check, _) = repo.run_cli(&["check", "--local-only", "--json"], None);
    assert!(!success);
    let check: Value = serde_json::from_str(&stdout_check).expect("check json");
    assert_eq!(check["eligible"], false);
    assert_eq!(check["summary"]["fail"], 1);
    let tag_finding = check["findings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["id"] == "tag_consistency")
        .unwrap();
    assert_eq!(tag_finding["verdict"], "fail");
}

#[test]
#[cfg(unix)]
#[allow(clippy::expect_used, clippy::unwrap_used)]
fn test_remote_ci_exact_sha_with_mock_gh() {
    let repo = TempRepo::new("mock-gh");
    let sha = repo.head_commit();

    let mock_bin_dir = std::env::temp_dir().join(format!("rf-mock-bin-{}", std::process::id()));
    let _ = fs::remove_dir_all(&mock_bin_dir);
    fs::create_dir_all(&mock_bin_dir).expect("create mock bin dir");
    let gh_script_path = mock_bin_dir.join("gh");

    // 1. Successful run matching exact SHA
    let gh_success_content = format!(
        r#"#!/usr/bin/env bash
if [[ "$*" == *"run list"* ]]; then
  echo '[{{"name":"CI","headBranch":"develop","headSha":"{sha}","status":"completed","conclusion":"success","url":"https://github.com/example/repo/actions/runs/1"}}]'
  exit 0
fi
exit 1
"#
    );
    fs::write(&gh_script_path, gh_success_content).expect("write mock gh");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&gh_script_path).unwrap().permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&gh_script_path, perms).unwrap();
    }

    // Create a local upstream repo
    let upstream = TempRepo::new("mock-gh-upstream");
    repo.git(&[
        "remote",
        "add",
        "origin",
        &upstream.path.display().to_string(),
    ]);
    // Configure upstream tracking branch in git
    repo.git(&["update-ref", "refs/remotes/origin/develop", &sha]);
    repo.git(&["branch", "--set-upstream-to", "origin/develop"]);

    let (success, stdout, _) = repo.run_cli(&["check"], Some(&mock_bin_dir));
    assert!(
        success,
        "check with successful exact-SHA CI should pass: {stdout}"
    );
    assert!(stdout.contains("ELIGIBLE FOR RELEASE"));
    assert!(stdout.contains("Exact commit"));

    // 2. Run matching a DIFFERENT SHA -> should fail!
    let different_sha = "2222222222222222222222222222222222222222";
    let gh_wrong_sha = format!(
        r#"#!/usr/bin/env bash
if [[ "$*" == *"run list"* ]]; then
  echo '[{{"name":"CI","headBranch":"develop","headSha":"{different_sha}","status":"completed","conclusion":"success","url":"https://github.com/example/repo/actions/runs/2"}}]'
  exit 0
fi
exit 1
"#
    );
    fs::write(&gh_script_path, gh_wrong_sha).expect("write mock gh");

    let (success, stdout, _) = repo.run_cli(&["check"], Some(&mock_bin_dir));
    assert!(!success, "check with different SHA must fail: {stdout}");
    assert!(stdout.contains("BLOCKED"));
    assert!(stdout.contains("No CI or Candidate workflow runs found for exact commit"));

    // 3. gh command failure (e.g. unauthenticated or offline) -> should fail closed with UNKNOWN
    let gh_error = r#"#!/usr/bin/env bash
echo "gh: not logged into any GitHub hosts" >&2
exit 1
"#;
    fs::write(&gh_script_path, gh_error).expect("write mock gh");

    let (success, stdout, _) = repo.run_cli(&["check"], Some(&mock_bin_dir));
    assert!(!success, "check when gh fails must fail closed: {stdout}");
    assert!(stdout.contains("[UNKNOWN]"));
    assert!(stdout.contains("Remote CI status could not be established"));
}
