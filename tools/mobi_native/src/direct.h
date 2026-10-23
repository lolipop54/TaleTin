/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later. */
#ifndef TALETIN_MOBI_DIRECT_H
#define TALETIN_MOBI_DIRECT_H
#include "extract.h"
#include <stdint.h>
#include <stddef.h>

/* A session is confined to one worker. It owns its file, dictionaries and
 * latest result; killing the Dart worker releases all of them via finalizer. */
typedef struct gt_mobi_session gt_mobi_session;
GT_EXPORT gt_mobi_session *gt_mobi_open(const char *source, int *status);
GT_EXPORT void gt_mobi_close(void *session);
/* Import scans may coalesce small compressed-record reads in a 64 KiB window.
 * Ordinary indexed chapter sessions leave this disabled. */
GT_EXPORT void gt_mobi_buffer_input(gt_mobi_session *session);
/* 0 records, 1 first text record, 2 text records, 3 first resource record,
 * 4 version, 5 encoding, 6 source bytes, 7 bytes read, 8 records decoded,
 * 9 live retained record bytes, 10 largest text record output,
 * 11 import window fills, 12 retained compressed input window bytes. */
GT_EXPORT uint64_t gt_mobi_info(gt_mobi_session *session, int field);
/* mode 0: original record, 1: decoded text record, 2: decoded resource.
 * A successful call replaces the result owned by this session. */
GT_EXPORT int gt_mobi_record(gt_mobi_session *session, uint32_t number, int mode);
GT_EXPORT const unsigned char *gt_mobi_result(gt_mobi_session *session);
GT_EXPORT size_t gt_mobi_result_size(gt_mobi_session *session);
GT_EXPORT uint64_t gt_mobi_record_offset(gt_mobi_session *session, uint32_t number);
GT_EXPORT uint64_t gt_mobi_record_size(gt_mobi_session *session, uint32_t number);
/* Index construction is incremental, so the worker can yield/cancel between
 * record batches and between chapters without retaining a whole rawml string. */
GT_EXPORT int gt_mobi_scan(gt_mobi_session *session, uint32_t records);
GT_EXPORT int gt_mobi_structure(gt_mobi_session *session);
GT_EXPORT uint32_t gt_mobi_entries(gt_mobi_session *session);
GT_EXPORT int gt_mobi_anchors(gt_mobi_session *session, uint32_t entry);
GT_EXPORT int gt_mobi_links(gt_mobi_session *session, uint32_t entry);
GT_EXPORT int gt_mobi_metadata(gt_mobi_session *session);
GT_EXPORT int gt_mobi_entry_info(gt_mobi_session *session, uint32_t entry);
GT_EXPORT int gt_mobi_entry_read(gt_mobi_session *session, uint32_t entry,
                                uint32_t offset, uint32_t length, int patched);
GT_EXPORT int gt_mobi_index_export(gt_mobi_session *session);
GT_EXPORT int gt_mobi_index_import(gt_mobi_session *session,
                                  const unsigned char *bytes, size_t length);
#endif
