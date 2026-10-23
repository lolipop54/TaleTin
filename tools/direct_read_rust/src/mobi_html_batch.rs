// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
use crate::{GtScanResult, mobi_html::MobiHtml, pool, result};
use rayon::prelude::*;
use std::slice;

pub struct MobiBatch {
    trees: Vec<MobiHtml>,
    output: Vec<u8>,
}

/// Private, length-prefixed UTF-8 packets supplied by Dart, never file data.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_batch_open(input: *const u8, length: usize) -> *mut MobiBatch {
    let bytes = unsafe { slice::from_raw_parts(input, length) };
    let mut sources = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        let size = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
        at += 4;
        sources.push(&bytes[at..at + size]);
        at += size;
    }
    let trees = pool().install(|| sources.into_par_iter().map(MobiHtml::new).collect());
    Box::into_raw(Box::new(MobiBatch { trees, output: Vec::new() }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_batch_refs(handle: *mut MobiBatch, output: *mut GtScanResult) {
    let batch = unsafe { &mut *handle };
    // par_iter_mut requires only Send: Rc graphs must never be shared via Sync.
    let refs: Vec<_> = pool().install(|| batch.trees.par_iter_mut().map(|h| h.refs()).collect());
    result(serde_json::to_vec(&refs).unwrap(), &mut batch.output, output);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_batch_finish(
    handle: *mut MobiBatch, input: *const u8, length: usize, output: *mut GtScanResult,
) {
    let edits: Vec<Vec<(usize, String, String)>> =
        serde_json::from_slice(unsafe { slice::from_raw_parts(input, length) }).unwrap();
    let batch = unsafe { &mut *handle };
    assert_eq!(edits.len(), batch.trees.len());
    let finished: Vec<_> = pool().install(|| batch.trees.par_iter_mut()
        .zip(edits.into_par_iter()).map(|(tree, edits)| tree.finish_edits(edits)).collect());
    let mut packet = Vec::with_capacity(finished.iter().map(|s| 4 + s.len()).sum());
    for bytes in finished {
        packet.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
        packet.extend_from_slice(&bytes);
    }
    result(packet, &mut batch.output, output);
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_batch_close(handle: *mut MobiBatch) {
    if !handle.is_null() { unsafe { drop(Box::from_raw(handle)); } }
}
