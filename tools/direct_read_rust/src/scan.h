// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
#include <stdint.h>
#include <stddef.h>
typedef struct GtScanResult {
  uint8_t *data;
  size_t length;
} GtScanResult;
// Result views belong to the handle until its next call/close. Legacy free is a no-op.
void gt_scan_free(uint8_t *data, size_t length);
void *gt_hash_open(void);
void gt_hash_feed(void *handle, const uint8_t *input, size_t length, uint32_t finish, GtScanResult *result);
void gt_hash_close(void *handle);
void gt_txt_hash_enable(void *handle);
void gt_txt_hash_result(void *handle, GtScanResult *result);
void *gt_inflate_open(void);
uint32_t gt_inflate_decode(void *handle, const uint8_t *input, size_t length, size_t limit, GtScanResult *result);
void gt_inflate_close(void *handle);
void *gt_text_open(uint32_t encoding);
void gt_text_feed(void *handle, const uint8_t *input, size_t length, uint32_t finish, GtScanResult *result);
void gt_text_close(void *handle);
void *gt_txt_open(uint32_t encoding, uint64_t offset);
void gt_txt_feed(void *handle, const uint8_t *input, size_t length, uint32_t finish, GtScanResult *result);
void gt_txt_close(void *handle);
void *gt_html_open(const uint8_t *input, size_t length);
void *gt_html_options(const uint8_t *input, size_t length, uint32_t optimized);
void *gt_html_bytes(const uint8_t *input, size_t length, uint32_t optimized);
void gt_html_refs(void *handle, GtScanResult *result);
void gt_html_convert(void *handle, const uint8_t *metadata, size_t length, uint32_t flags, GtScanResult *result);
void gt_html_close(void *handle);
void *gt_html_batch_open(const uint8_t *input, size_t length);
void *gt_html_batch_options(const uint8_t *input, size_t length, uint32_t optimized);
void *gt_html_batch_bytes(const uint8_t *input, size_t length, uint32_t optimized);
void gt_html_batch_refs(void *handle, GtScanResult *result);
void gt_html_batch_convert(void *handle, const uint8_t *input, size_t length, GtScanResult *result);
void gt_html_batch_convert_flags(void *handle, const uint8_t *input, size_t length, uint32_t flags, GtScanResult *result);
void gt_html_batch_close(void *handle);
void gt_html_batch_timings(void *handle, GtScanResult *result);
void *gt_original_open(const uint8_t *dictionary, size_t length);
void gt_original_transform(void *handle, const uint8_t *input, size_t length, GtScanResult *result);
void gt_original_close(void *handle);
void gt_original_timings(void *handle, GtScanResult *result);
