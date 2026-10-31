use clap::{Arg, ArgAction, Command};

/// Define the CLI interface; business logic belongs to the action handlers.
#[must_use]
pub fn new() -> Command {
    Command::new("release-flow")
        .version(env!("CARGO_PKG_VERSION"))
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
        assert!(new().try_get_matches_from(["release-flow", "plan", "patch"]).is_ok());
    }

    #[test]
    fn rejects_unknown_bump() {
        assert!(new().try_get_matches_from(["release-flow", "plan", "experimental"]).is_err());
    }
}
