pub mod plan;
pub mod status;

use crate::release::version::Bump;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Status { json: bool },
    Plan { bump: Bump, json: bool },
}
