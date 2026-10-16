// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use sha2::{Digest, Sha256};
pub struct Hash {
    pub state: Sha256,
    pub output: Vec<u8>,
}
impl Hash {
    pub fn new() -> Self {
        Self {
            state: Sha256::new(),
            output: Vec::new(),
        }
    }
    pub fn feed(&mut self, bytes: &[u8], finish: bool) -> Vec<u8> {
        self.state.update(bytes);
        if finish {
            self.state.clone().finalize().to_vec()
        } else {
            Vec::new()
        }
    }
}
