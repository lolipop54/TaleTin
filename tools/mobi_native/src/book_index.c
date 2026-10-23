/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
 * Portable little-endian recipe index. No body text, compressed records or
 * image/font payloads are serialized. Generated OPF/NCX are metadata only. */
#include "book_internal.h"
#include "memory.h"
#include "util.h"
#include <stdlib.h>
#include <string.h>

#define GT_INDEX_LIMIT (50u * 1024 * 1024)
typedef struct { unsigned char *data; size_t size, capacity; int status; } GTWriter;
typedef struct { const unsigned char *data; size_t size, at; int status; } GTReader;

static void put(GTWriter *w, const void *data, size_t length) {
    if (w->status) return;
    if (length > GT_INDEX_LIMIT - w->size) { w->status = 4; return; }
    if (w->size + length > w->capacity) {
        size_t capacity = w->capacity ? w->capacity * 2 : 4096;
        if (capacity < w->size + length) capacity = w->size + length;
        if (capacity > GT_INDEX_LIMIT) capacity = GT_INDEX_LIMIT;
        unsigned char *grown = realloc(w->data, capacity);
        if (!grown) { w->status = 5; return; }
        w->data = grown; w->capacity = capacity;
    }
    memcpy(w->data + w->size, data, length); w->size += length;
}
static void u32(GTWriter *w, uint32_t value) {
    unsigned char bytes[4] = {(unsigned char)value, (unsigned char)(value >> 8),
                             (unsigned char)(value >> 16), (unsigned char)(value >> 24)};
    put(w, bytes, 4);
}
static uint32_t get(GTReader *r) {
    if (r->status || r->size - r->at < 4) { r->status = 1; return 0; }
    const unsigned char *p = r->data + r->at; r->at += 4;
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static unsigned char *copy(GTReader *r, size_t length) {
    if (r->status || length > r->size - r->at) { r->status = 1; return NULL; }
    unsigned char *bytes = malloc(length ? length : 1);
    if (!bytes) { r->status = 5; return NULL; }
    memcpy(bytes, r->data + r->at, length); r->at += length;
    return bytes;
}

int gt_mobi_index_export(gt_mobi_session *s) {
    if (!s || !s->book || !s->book->raw) return 1;
    gt_mobi_book *b = s->book;
    GTWriter w = {0};
    put(&w, "GTMOBI02", 8);
    u32(&w, (uint32_t)s->source_size); u32(&w, (uint32_t)s->count);
    u32(&w, (uint32_t)s->first_text); u32(&w, (uint32_t)s->text_count);
    u32(&w, (uint32_t)b->raw->version); u32(&w, b->entry_count);
    for (uint32_t i = 0; i <= b->scanned; i++) u32(&w, b->text_starts[i]);
    for (uint32_t i = 0; i < b->entry_count; i++) {
        GTEntry *e = &b->entries[i];
        u32(&w, (uint32_t)e->kind); u32(&w, (uint32_t)e->meta->uid);
        u32(&w, (uint32_t)e->meta->type); u32(&w, (uint32_t)e->meta->size);
        u32(&w, e->output_size); u32(&w, e->span_count); u32(&w, e->patch_count);
        for (uint32_t j = 0; j < e->span_count; j++) {
            u32(&w, e->spans[j].offset); u32(&w, e->spans[j].length);
        }
        for (uint32_t j = 0; j < e->patch_count; j++) {
            GTPatch *p = &e->patches[j];
            u32(&w, p->offset); u32(&w, p->removed); u32(&w, p->length); put(&w, p->data, p->length);
        }
        if (e->kind == 3) put(&w, e->meta->data, e->meta->size);
    }
    if (w.status) { free(w.data); return w.status; }
    free(s->result); s->result = w.data; s->result_size = w.size;
    return 0;
}

int gt_mobi_index_import(gt_mobi_session *s, const unsigned char *bytes, size_t length) {
    if (!s || s->book || length < 36 || length > GT_INDEX_LIMIT || memcmp(bytes, "GTMOBI02", 8)) return 1;
    GTReader r = {bytes, length, 8, 0};
    if (get(&r) != s->source_size || get(&r) != s->count ||
        get(&r) != s->first_text || get(&r) != s->text_count ||
        get(&r) != mobi_get_fileversion(s->m)) return 1;
    uint32_t count = get(&r);
    if (!count || count > 20000) return 4;
    gt_mobi_book *b = calloc(1, sizeof(*b));
    if (!b) return 5;
    b->session = s; b->scanned = (uint32_t)s->text_count;
    b->raw = mobi_init_rawml(s->m);
    b->text_starts = calloc(s->text_count + 1, sizeof(uint32_t));
    b->entries = calloc(count, sizeof(GTEntry));
    if (!b->raw || !b->text_starts || !b->entries) { gt_book_free(b); return 5; }
    uint32_t max_record = mobi_get_textrecord_maxsize(s->m);
    for (uint32_t i = 0; i <= b->scanned && !r.status; i++) {
        uint32_t value = get(&r);
        if ((!i && value) || value > 1024 * 1024 * 1024 ||
            (i && (value < b->text_starts[i - 1] || value - b->text_starts[i - 1] > max_record))) r.status = 1;
        b->text_starts[i] = value;
    }
    MOBIPart **markup_tail = &b->raw->markup, **flow_tail = &b->raw->flow, **resource_tail = &b->raw->resources;
    for (uint32_t i = 0; i < count && !r.status; i++) {
        GTEntry *e = &b->entries[i];
        e->kind = (int)get(&r);
        MOBIPart *part = calloc(1, sizeof(*part));
        if (!part) { r.status = 5; break; }
        e->meta = part; b->entry_count++;
        if (e->kind == 0) { *markup_tail = part; markup_tail = &part->next; b->markup_count++; }
        else if (e->kind == 1) { *flow_tail = part; flow_tail = &part->next; b->flow_count++; }
        else { *resource_tail = part; resource_tail = &part->next; }
        part->uid = get(&r); part->type = (MOBIFiletype)get(&r); part->size = get(&r);
        e->output_size = get(&r); uint32_t spans = get(&r), patches = get(&r);
        if (e->kind < 0 || e->kind > 3 || part->uid >= 200000 ||
            part->type < T_UNKNOWN || part->type > T_VIDEO ||
            part->size > 1024 * 1024 * 1024 || e->output_size > 1024 * 1024 * 1024 ||
            (uint64_t)spans * 8 + (uint64_t)patches * 12 > r.size - r.at) { r.status = 1; break; }
        if (e->kind < 2) {
            if (!spans) { r.status = 1; break; }
        } else if (spans || patches || part->size > 50 * 1024 * 1024 || e->output_size != part->size) {
            r.status = 1; break;
        }
        if (e->kind == 2 && (s->resource_first >= s->count || part->uid >= s->count - s->resource_first)) { r.status = 1; break; }
        if (e->kind == 3 && part->type != T_OPF && part->type != T_NCX) { r.status = 1; break; }
        e->spans = calloc(spans ? spans : 1, sizeof(GTSpan));
        e->patches = calloc(patches ? patches : 1, sizeof(GTPatch));
        if (!e->spans || !e->patches) { r.status = 5; break; }
        uint64_t sum = 0;
        for (uint32_t j = 0; j < spans && !r.status; j++) {
            GTSpan *span = &e->spans[e->span_count++];
            span->offset = get(&r); span->length = get(&r);
            uint32_t total = b->text_starts[b->scanned];
            if (span->offset > total || span->length > total - span->offset) r.status = 1;
            sum += span->length;
        }
        if (e->kind < 2 && sum != part->size) r.status = 1;
        uint32_t previous = 0, output_at = 0; uint64_t output_size = part->size;
        for (uint32_t j = 0; j < patches && !r.status; j++) {
            GTPatch *p = &e->patches[e->patch_count++];
            p->offset = get(&r); p->removed = get(&r); p->length = get(&r);
            if (p->offset < previous || p->offset > part->size || p->removed > part->size - p->offset || p->length > 151) { r.status = 1; break; }
            output_at += p->offset - previous + p->length;
            p->output_end = output_at;
            p->data = copy(&r, p->length); previous = p->offset + p->removed;
            output_size = output_size - p->removed + p->length;
        }
        if (output_size != e->output_size) r.status = 1;
        if (e->kind == 3) part->data = copy(&r, part->size);
        if (e->kind == 3 && part->type == T_OPF) strcpy(e->name, "content.opf");
        else snprintf(e->name, sizeof(e->name), "%s%05zu.%s", e->kind == 0 ? "part" : e->kind == 1 ? "flow" : "resource",
                      part->uid, mobi_get_filemeta_by_type(part->type).extension);
        for (uint32_t j = 0; j < i && !r.status; j++) if (!strcmp(e->name, b->entries[j].name)) r.status = 1;
    }
    if (r.at != length) r.status = 1;
    if (r.status) { gt_book_free(b); return r.status; }
    s->book = b;
    return 0;
}
