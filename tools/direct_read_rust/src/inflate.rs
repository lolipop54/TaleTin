// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use flate2::{Decompress, FlushDecompress, Status};

/// Bound actual output while inflating, even if a ZIP header lies about size.
pub fn decode(input: &[u8], limit: usize) -> Result<Vec<u8>, i32> {
    let mut decoder = Decompress::new(false);
    let mut output = Vec::with_capacity(input.len().saturating_mul(3).min(limit));
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let before_in = decoder.total_in();
        let before_out = decoder.total_out();
        let size = buffer.len().min(limit.saturating_sub(output.len()) + 1);
        let status = decoder
            .decompress(
                &input[before_in as usize..],
                &mut buffer[..size],
                FlushDecompress::None,
            )
            .map_err(|_| 1)?;
        let written = (decoder.total_out() - before_out) as usize;
        output.extend_from_slice(&buffer[..written]);
        if output.len() > limit {
            return Err(2);
        }
        if status == Status::StreamEnd {
            return Ok(output);
        }
        if decoder.total_in() == before_in && written == 0 {
            return Err(1);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    #[test]
    fn rejects_truncation_and_limits_actual_output() {
        let mut encoder =
            flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(&vec![b'x'; 200000]).unwrap();
        let zipped = encoder.finish().unwrap();
        assert_eq!(decode(&zipped, 200000).unwrap(), vec![b'x'; 200000]);
        assert_eq!(decode(&zipped, 199999), Err(2));
        assert_eq!(decode(&zipped[..zipped.len() / 2], 200000), Err(1));
    }
}
