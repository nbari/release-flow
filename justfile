default:
  @just --list

# Local gate used by CI. The lockfile is deliberately required.
check:
  cargo fmt --all -- --check
  cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
  cargo test --locked --workspace --all-features
  bash tests/candidate-verification.sh

build:
  cargo build --release --locked

# Inspect the current clone; never modifies the repository.
status:
  cargo run --locked -- status

# Manually dispatch the candidate pipeline on the current branch.
candidate:
  gh workflow run candidate.yml --ref "$(git branch --show-current)"
