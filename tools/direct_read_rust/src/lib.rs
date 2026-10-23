// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
mod dom;
mod hash;
mod html;
mod html_anchors;
mod inflate;
mod mobi_html;
mod mobi_html_batch;
mod original;
mod original_hyphen;
mod original_serialize;
mod text;
mod txt;
use rayon::prelude::*;
use std::sync::OnceLock;
use std::{ptr, slice};
pub struct Batch {
    trees: Vec<html::Html>,
    output: Vec<u8>,
    parse_us: u64,
    convert_us: u64,
    input_bytes: usize,
}
pub struct Inflate {
    output: Vec<u8>,
}
fn pool() -> &'static rayon::ThreadPool {
    static POOL: OnceLock<rayon::ThreadPool> = OnceLock::new();
    POOL.get_or_init(|| {
        rayon::ThreadPoolBuilder::new()
            .num_threads(
                std::thread::available_parallelism()
                    .map(|v| v.get())
                    .unwrap_or(1)
                    .min(4),
            )
            .thread_name(|i| format!("gt-epub-{i}"))
            .build()
            .unwrap()
    })
}

#[repr(C)]
pub struct GtScanResult {
    pub data: *mut u8,
    pub length: usize,
}

fn result(bytes: Vec<u8>, owner: &mut Vec<u8>, output: *mut GtScanResult) {
    // Borrowed output belongs to the handle. Replacing/closing the handle frees it,
    // including when a Dart isolate is killed before its finally block can run.
    *owner = bytes;
    unsafe {
        ptr::write(
            output,
            GtScanResult {
                data: owner.as_mut_ptr(),
                length: owner.len(),
            },
        );
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_html_open(
    input: *const u8,
    length: usize,
) -> *mut mobi_html::MobiHtml {
    Box::into_raw(Box::new(mobi_html::MobiHtml::new(unsafe {
        slice::from_raw_parts(input, length)
    })))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_html_refs(
    handle: *mut mobi_html::MobiHtml,
    output: *mut GtScanResult,
) {
    let html = unsafe { &mut *handle };
    result(
        serde_json::to_vec(&html.refs()).unwrap(),
        &mut html.output,
        output,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_html_finish(
    handle: *mut mobi_html::MobiHtml,
    input: *const u8,
    length: usize,
    output: *mut GtScanResult,
) {
    let html = unsafe { &mut *handle };
    let bytes = html.finish(unsafe { slice::from_raw_parts(input, length) });
    result(bytes, &mut html.output, output);
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_mobi_html_close(handle: *mut mobi_html::MobiHtml) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_scan_free(_data: *mut u8, _length: usize) {}

#[unsafe(no_mangle)]
pub extern "C" fn gt_hash_open() -> *mut hash::Hash {
    Box::into_raw(Box::new(hash::Hash::new()))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_hash_feed(
    handle: *mut hash::Hash,
    input: *const u8,
    length: usize,
    finish: u32,
    output: *mut GtScanResult,
) {
    let h = unsafe { &mut *handle };
    let bytes = unsafe { slice::from_raw_parts(input, length) };
    result(h.feed(bytes, finish != 0), &mut h.output, output);
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_hash_close(handle: *mut hash::Hash) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_txt_hash_enable(handle: *mut txt::Scanner) {
    unsafe { &mut *handle }.hash = Some(hash::Hash::new());
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_txt_hash_result(handle: *mut txt::Scanner, output: *mut GtScanResult) {
    let scanner = unsafe { &mut *handle };
    let bytes = scanner.hash.as_mut().unwrap().feed(&[], true);
    result(bytes, &mut scanner.output, output);
}
#[unsafe(no_mangle)]
pub extern "C" fn gt_inflate_open() -> *mut Inflate {
    Box::into_raw(Box::new(Inflate { output: Vec::new() }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_inflate_decode(
    handle: *mut Inflate,
    input: *const u8,
    length: usize,
    limit: usize,
    output: *mut GtScanResult,
) -> u32 {
    let h = unsafe { &mut *handle };
    match inflate::decode(unsafe { slice::from_raw_parts(input, length) }, limit) {
        Ok(bytes) => {
            result(bytes, &mut h.output, output);
            0
        }
        Err(code) => {
            result(Vec::new(), &mut h.output, output);
            code as u32
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_inflate_close(handle: *mut Inflate) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn gt_text_open(encoding: u32) -> *mut text::TextDecoder {
    Box::into_raw(Box::new(text::TextDecoder::new(encoding)))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_text_feed(
    handle: *mut text::TextDecoder,
    input: *const u8,
    length: usize,
    finish: u32,
    output: *mut GtScanResult,
) {
    let decoder = unsafe { &mut *handle };
    let bytes = unsafe { slice::from_raw_parts(input, length) };
    result(
        decoder.feed(bytes, finish != 0),
        &mut decoder.output,
        output,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_text_close(handle: *mut text::TextDecoder) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}

/// Each handle belongs to one Dart isolate. Input pointers are borrowed only during a call.
#[unsafe(no_mangle)]
pub extern "C" fn gt_txt_open(encoding: u32, offset: u64) -> *mut txt::Scanner {
    Box::into_raw(Box::new(txt::Scanner::new(encoding, offset)))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_txt_feed(
    handle: *mut txt::Scanner,
    input: *const u8,
    length: usize,
    finish: u32,
    output: *mut GtScanResult,
) {
    let bytes = unsafe { slice::from_raw_parts(input, length) };
    let scanner = unsafe { &mut *handle };
    result(
        scanner.feed(bytes, finish != 0),
        &mut scanner.output,
        output,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_txt_close(handle: *mut txt::Scanner) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_open(input: *const u8, length: usize) -> *mut html::Html {
    unsafe { gt_html_options(input, length, 0) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_options(
    input: *const u8,
    length: usize,
    optimized: u32,
) -> *mut html::Html {
    Box::into_raw(Box::new(html::Html::with_options(
        unsafe { slice::from_raw_parts(input, length) },
        optimized != 0,
    )))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_bytes(
    input: *const u8,
    length: usize,
    optimized: u32,
) -> *mut html::Html {
    Box::into_raw(Box::new(html_from_bytes(
        unsafe { slice::from_raw_parts(input, length) },
        optimized != 0,
    )))
}
// Keep single-chapter and full-book statistics decoding exactly the same.
fn html_from_bytes(source: &[u8], optimized: bool) -> html::Html {
    let encoding = if source.starts_with(&[0xff, 0xfe]) { 1 }
        else if source.starts_with(&[0xfe, 0xff]) { 2 } else { 0 };
    let decoded = text::decode(source, encoding);
    html::Html::with_options(decoded.strip_prefix('\u{feff}').unwrap_or(&decoded).as_bytes(), optimized)
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_refs(handle: *mut html::Html, output: *mut GtScanResult) {
    let html = unsafe { &mut *handle };
    result(
        serde_json::to_vec(&html.refs()).unwrap(),
        &mut html.output,
        output,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_convert(
    handle: *mut html::Html,
    metadata: *const u8,
    length: usize,
    flags: u32,
    output: *mut GtScanResult,
) {
    let metadata =
        serde_json::from_slice(unsafe { slice::from_raw_parts(metadata, length) }).unwrap();
    let html = unsafe { &mut *handle };
    result(
        serde_json::to_vec(&html.convert(metadata, flags)).unwrap(),
        &mut html.output,
        output,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_close(handle: *mut html::Html) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_anchor_positions(handle: *mut html::Html,
    input: *const u8, length: usize, output: *mut GtScanResult) {
    let metadata = serde_json::from_slice(unsafe { slice::from_raw_parts(input, length) }).unwrap();
    let html = unsafe { &mut *handle };
    result(serde_json::to_vec(&html.anchor_positions(metadata)).unwrap(), &mut html.output, output);
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_open(input: *const u8, length: usize) -> *mut Batch {
    unsafe { gt_html_batch_options(input, length, 0) }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_options(
    input: *const u8,
    length: usize,
    optimized: u32,
) -> *mut Batch {
    let clock = std::time::Instant::now();
    let sources: Vec<String> =
        serde_json::from_slice(unsafe { slice::from_raw_parts(input, length) }).unwrap();
    let trees = pool().install(|| {
        sources
            .into_par_iter()
            .map(|s| html::Html::with_options(s.as_bytes(), optimized != 0))
            .collect()
    });
    Box::into_raw(Box::new(Batch {
        trees,
        output: Vec::new(),
        parse_us: clock.elapsed().as_micros() as u64,
        convert_us: 0,
        input_bytes: length,
    }))
}
/// Input is a private length-prefixed packet from Dart, not an EPUB file format.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_bytes(
    input: *const u8,
    length: usize,
    optimized: u32,
) -> *mut Batch {
    let clock = std::time::Instant::now();
    let bytes = unsafe { slice::from_raw_parts(input, length) };
    let mut at = 0;
    let mut sources = Vec::new();
    while at < bytes.len() {
        let size = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
        at += 4;
        sources.push(&bytes[at..at + size]);
        at += size;
    }
    let trees = pool().install(|| {
        sources
            .into_par_iter()
            .map(|s| html_from_bytes(s, optimized != 0))
            .collect()
    });
    Box::into_raw(Box::new(Batch {
        trees,
        output: Vec::new(),
        parse_us: clock.elapsed().as_micros() as u64,
        convert_us: 0,
        input_bytes: length,
    }))
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_refs(handle: *mut Batch, output: *mut GtScanResult) {
    let batch = unsafe { &mut *handle };
    result(
        serde_json::to_vec(&batch.trees.iter().map(html::Html::refs).collect::<Vec<_>>()).unwrap(),
        &mut batch.output,
        output,
    );
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_convert(
    handle: *mut Batch,
    input: *const u8,
    length: usize,
    output: *mut GtScanResult,
) {
    unsafe {
        gt_html_batch_convert_flags(handle, input, length, 1, output);
    }
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_convert_flags(
    handle: *mut Batch,
    input: *const u8,
    length: usize,
    flags: u32,
    output: *mut GtScanResult,
) {
    let clock = std::time::Instant::now();
    let metadata: Vec<serde_json::Value> =
        serde_json::from_slice(unsafe { slice::from_raw_parts(input, length) }).unwrap();
    let batch = unsafe { &mut *handle };
    let converted: Vec<_> = pool().install(|| {
        batch
            .trees
            .par_iter_mut()
            .zip(metadata.into_par_iter())
            .map(|(h, m)| h.convert(m, flags))
            .collect()
    });
    result(
        serde_json::to_vec(&converted).unwrap(),
        &mut batch.output,
        output,
    );
    batch.convert_us = clock.elapsed().as_micros() as u64;
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_timings(handle: *mut Batch, output: *mut GtScanResult) {
    let batch = unsafe { &mut *handle };
    let bytes = serde_json::to_vec(&serde_json::json!({
        "html_native_parse_wall": batch.parse_us,
        "html_native_convert_wall": batch.convert_us,
        "html_input_bytes": batch.input_bytes,
        "html_result_bytes": batch.output.len(),
    }))
    .unwrap();
    result(bytes, &mut batch.output, output);
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn gt_html_batch_close(handle: *mut Batch) {
    if !handle.is_null() {
        unsafe {
            drop(Box::from_raw(handle));
        }
    }
}
