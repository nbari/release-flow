default:
    @just --list

fmt:
    cargo fmt --all -- --check

clippy:
    cargo clippy --locked --workspace --all-targets --all-features -- -D warnings

test:
    cargo test --locked --workspace --all-features

check: fmt clippy test
    cargo build --release --locked

build:
    cargo build --release --locked

status:
    cargo run --locked -- status --json

plan bump="patch":
    cargo run --locked -- plan {{ quote(bump) }} --json
