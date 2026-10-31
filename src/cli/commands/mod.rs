use clap::{
    Arg, ArgAction, ColorChoice, Command,
    builder::styling::{AnsiColor, Effects, Styles},
};

#[allow(clippy::doc_markdown)]
pub mod built_info {
    include!(concat!(env!("OUT_DIR"), "/built.rs"));
}
static LONG_VERSION: std::sync::LazyLock<String> = std::sync::LazyLock::new(|| {
    let git_hash = built_info::GIT_COMMIT_HASH.unwrap_or("unknown");
    format!("{} - {git_hash}", env!("CARGO_PKG_VERSION"))
});

/// Define the CLI interface; business logic belongs to the action handlers.
#[must_use]
pub fn new() -> Command {
    let styles = Styles::styled()
        .header(AnsiColor::Yellow.on_default() | Effects::BOLD)
        .usage(AnsiColor::Green.on_default() | Effects::BOLD)
        .literal(AnsiColor::Blue.on_default() | Effects::BOLD)
        .placeholder(AnsiColor::Green.on_default());
    Command::new("release-flow")
        .version(env!("CARGO_PKG_VERSION"))
        .long_version(LONG_VERSION.as_str())
        .color(ColorChoice::Auto)
        .styles(styles)
        .about("Inspect release readiness and CI pipeline state")
        .arg(
            Arg::new("verbose")
                .short('v')
                .long("verbose")
                .global(true)
                .action(ArgAction::Count),
        )
        .subcommand_required(true)
        .arg_required_else_help(true)
        .subcommand(
            Command::new("status")
                .about("Inspect the local checkout, release tags and recent GitHub Actions")
                .arg(json_arg()),
        )
        .subcommand(
            Command::new("plan")
                .about("Preview a version bump without changing repository state")
                .arg(
                    Arg::new("bump")
                        .required(true)
                        .value_parser(["patch", "minor", "major"]),
                )
                .arg(json_arg()),
        )
        .subcommand(
            Command::new("check")
                .about("Evaluate release readiness and release gates")
                .arg(json_arg())
                .arg(
                    Arg::new("local-only")
                        .long("local-only")
                        .help("Evaluate only local repository invariants, skipping remote CI verification")
                        .action(ArgAction::SetTrue),
                ),
        )
}

fn json_arg() -> Arg {
    Arg::new("json")
        .long("json")
        .help("Emit machine-readable JSON")
        .action(ArgAction::SetTrue)
}

#[cfg(test)]
mod tests {
    use super::new;

    #[test]
    fn accepts_patch_plan() {
        assert!(
            new()
                .try_get_matches_from(["release-flow", "plan", "patch"])
                .is_ok()
        );
    }

    #[test]
    fn rejects_unknown_bump() {
        assert!(
            new()
                .try_get_matches_from(["release-flow", "plan", "experimental"])
                .is_err()
        );
    }

    #[test]
    fn accepts_check() {
        assert!(
            new()
                .try_get_matches_from(["release-flow", "check", "--json", "--local-only"])
                .is_ok()
        );
    }
}
