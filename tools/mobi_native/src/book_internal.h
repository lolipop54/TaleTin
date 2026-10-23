/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later. */
#ifndef TALETIN_MOBI_BOOK_INTERNAL_H
#define TALETIN_MOBI_BOOK_INTERNAL_H
#include "direct_internal.h"
#include "parse_rawml.h"

typedef struct { uint32_t offset, length; } GTSpan;
typedef struct {
    uint32_t offset, removed, length;
    unsigned char *data;
    /* Rebuilt in memory; the portable index format is unchanged. */
    uint32_t output_end;
} GTPatch;
typedef struct { uint32_t tag, end, kind; char *value; } GTAnchor;
typedef struct {
    MOBIPart *meta;
    uint32_t span_count, patch_count, anchor_count;
    GTSpan *spans;
    GTPatch *patches;
    GTAnchor *anchors;
    uint32_t output_size;
    unsigned char *literal;
    char name[64];
    int kind; /* 0 markup, 1 flow, 2 resource, 3 generated metadata */
} GTEntry;
typedef struct { uint32_t record, size; unsigned char *data; } GTDecoded;

struct gt_mobi_book {
    gt_mobi_session *session;
    uint32_t *text_starts;
    uint32_t scanned;
    MOBIRawml *raw;
    GTEntry *entries;
    uint32_t entry_count, markup_count, flow_count;
    GTDecoded decoded[8];
    uint32_t cache_cursor;
};

int gt_text_into(gt_mobi_book *book, uint32_t offset, uint32_t length, unsigned char *output);
int gt_entry_into(gt_mobi_book *book, const GTEntry *entry, uint32_t offset, uint32_t length, unsigned char *output);
int gt_entry_patch(gt_mobi_book *book, GTEntry *entry);
int gt_entry_anchors(gt_mobi_book *book, GTEntry *entry);
MOBI_RET gt_position_id(const void *context, uint32_t *number, char *id,
                       size_t fid, size_t offset, int *preferred);
int gt_book_structure(gt_mobi_book *book);
typedef int (*GTTagCallback)(gt_mobi_book *, GTEntry *, const unsigned char *, uint32_t, uint32_t, void *);
int gt_walk_tags(gt_mobi_book *book, GTEntry *entry, GTTagCallback callback, void *context);
#endif
