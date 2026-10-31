use crate::{cli::actions::Action, release::version::Bump};
use anyhow::{Context, Result, bail};
use clap::ArgMatches;

/// Resolve clap matches into a typed action without performing IO.
pub fn handler(matches: &ArgMatches) -> Result<Action> {
    match matches.subcommand() {
        Some(("status", args)) => Ok(Action::Status {
            json: args.get_flag("json"),
        }),
        Some(("plan", args)) => {
            let bump = args
                .get_one::<String>("bump")
                .context("missing bump type")?;
            let bump = match bump.as_str() {
                "patch" => Bump::Patch,
                "minor" => Bump::Minor,
                "major" => Bump::Major,
                _ => bail!("unsupported bump: {bump}"),
            };
            Ok(Action::Plan {
                bump,
                json: args.get_flag("json"),
            })
        }
        _ => bail!("missing or unsupported command"),
    }
}

#[cfg(test)]
mod tests {
    use super::handler;
    use crate::{cli::{actions::Action, commands}, release::version::Bump};

    #[test]
    fn maps_plan_to_typed_action() {
        let matches = commands::new()
            .try_get_matches_from(["release-flow", "plan", "minor", "--json"])
            .expect("valid CLI");
        assert!(matches!(
            handler(&matches).expect("valid action"),
            Action::Plan {
                bump: Bump::Minor,
                json: true
            }
        ));
    }
}
