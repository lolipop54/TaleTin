/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
 * libmobi supplies the structural metadata; spans replace its full flow buffer. */
#include "book_internal.h"
#include "read.h"
#include "index.h"
#include "memory.h"
#include "util.h"
#include <stdlib.h>
#include <string.h>

/* Internal libmobi helper (the upstream public header omits this declaration). */
MOBIFiletype mobi_determine_font_type(const unsigned char *data, size_t length);

static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

static int load_index(gt_mobi_book *b, MOBIIndx **target, uint32_t *index) {
    if (!index || *index == UINT32_MAX) return 0;
    gt_mobi_session *s = b->session;
    size_t first = *index + mobi_get_kf8offset(s->m);
    if (gt_load(s, first)) return 1;
    MOBIPdbRecord *record = s->records[first];
    if (record->size < 56 || memcmp(record->data, "INDX", 4)) return 1;
    uint32_t count = be32(record->data + 24), cncx = be32(record->data + 52);
    if (count > 20000 || cncx > 15 || count + cncx >= s->count - first) return 4;
    for (size_t i = 1; i <= count + cncx; i++) if (gt_load(s, first + i)) return 1;
    MOBIIndx *parsed = mobi_init_indx();
    if (!parsed) return 5;
    /* On failure libmobi's parser has already freed parsed. */
    if (mobi_parse_index(s->m, parsed, first) != MOBI_SUCCESS) return 1;
    *target = parsed;
    return 0;
}

static GTEntry *entry_add(gt_mobi_book *b, MOBIPart *part, int kind, const char *prefix) {
    if (b->entry_count >= 19998) return NULL;
    GTEntry *e = &b->entries[b->entry_count++];
    e->meta = part; e->kind = kind; e->output_size = (uint32_t)part->size;
    snprintf(e->name, sizeof(e->name), "%s%05zu.%s", prefix, part->uid,
             mobi_get_filemeta_by_type(part->type).extension);
    return e;
}

static int span_set(GTEntry *e, uint32_t offset, uint32_t length) {
    e->spans = malloc(sizeof(GTSpan));
    if (!e->spans) return 5;
    e->spans[0] = (GTSpan){offset, length}; e->span_count = 1;
    return 0;
}

static int span_insert(GTEntry *e, uint32_t at, GTSpan inserted) {
    uint32_t position = 0;
    for (uint32_t i = 0; i < e->span_count; i++) {
        GTSpan old = e->spans[i];
        if (at > position + old.length) { position += old.length; continue; }
        uint32_t cut = at - position;
        GTSpan *next = realloc(e->spans, (e->span_count + 2) * sizeof(GTSpan));
        if (!next) return 5;
        e->spans = next;
        memmove(next + i + 3, next + i + 1, (e->span_count - i - 1) * sizeof(GTSpan));
        next[i] = (GTSpan){old.offset, cut};
        next[i + 1] = inserted;
        next[i + 2] = (GTSpan){old.offset + cut, old.length - cut};
        e->span_count += 2;
        e->meta->size += inserted.length;
        e->output_size += inserted.length;
        return 0;
    }
    return 1;
}

static int build_markup(gt_mobi_book *b) {
    MOBIRawml *raw = b->raw;
    uint32_t total = (uint32_t)raw->flow->size;
    uint32_t flow_start = raw->fdst ? raw->fdst->fdst_section_starts[0] : 0;
    if (!raw->skel || !raw->skel->entries_count) {
        raw->markup = calloc(1, sizeof(MOBIPart));
        if (!raw->markup) return 5;
        raw->markup->size = total; raw->markup->type = T_HTML;
        GTEntry *e = entry_add(b, raw->markup, 0, "part");
        b->markup_count = 1;
        return e ? span_set(e, flow_start, total) : 4;
    }
    if (!raw->frag || raw->skel->entries_count > 20000) return 1;
    MOBIPart **tail = &raw->markup;
    uint32_t current = 0, frag_index = 0;
    for (uint32_t i = 0; i < raw->skel->entries_count; i++) {
        MOBIIndexEntry *index = &raw->skel->entries[i];
        uint32_t count, offset, size;
        if (mobi_get_indxentry_tagvalue(&count, index, INDX_TAG_SKEL_COUNT) ||
            mobi_get_indxentry_tagvalue(&offset, index, INDX_TAG_SKEL_POSITION) ||
            mobi_get_indxentry_tagvalue(&size, index, INDX_TAG_SKEL_LENGTH) ||
            offset > total || size > total - offset ||
            count > raw->frag->entries_count - frag_index) return 1;
        MOBIPart *part = calloc(1, sizeof(*part));
        if (!part) return 5;
        *tail = part; tail = &part->next;
        part->uid = i; part->size = size; part->type = T_HTML;
        GTEntry *e = entry_add(b, part, 0, "part");
        if (!e) return 4;
        if (span_set(e, flow_start + offset, size)) return 5;
        uint32_t cursor = offset + size;
        while (count--) {
            MOBIIndexEntry *fragment = &raw->frag->entries[frag_index++];
            unsigned long absolute = strtoul(fragment->label, NULL, 10);
            uint32_t file, length;
            if (absolute < current || absolute > UINT32_MAX ||
                mobi_get_indxentry_tagvalue(&file, fragment, INDX_TAG_FRAG_FILE_NR) || file != i ||
                mobi_get_indxentry_tagvalue(&length, fragment, INDX_TAG_FRAG_LENGTH) ||
                cursor > total || length > total - cursor) return 1;
            uint32_t insert = (uint32_t)absolute - current;
            if (insert > part->size) insert = (uint32_t)part->size;
            int status = span_insert(e, insert, (GTSpan){flow_start + cursor, length});
            if (status) return status;
            cursor += length;
        }
        current += (uint32_t)part->size;
        b->markup_count++;
    }
    return 0;
}

static int build_resources(gt_mobi_book *b) {
    gt_mobi_session *s = b->session;
    MOBIPart **tail = &b->raw->resources;
    size_t first = s->resource_first == MOBI_NOTSET ? 0 : s->resource_first;
    for (size_t i = first; i < s->count; i++) {
        MOBIPdbRecord *record = s->records[i];
        unsigned char header[64] = {0};
        size_t length = record->size < sizeof(header) ? record->size : sizeof(header);
        if (fseek(s->file, (long)record->offset, SEEK_SET) || fread(header, 1, length, s->file) != length) return 5;
        s->bytes_read += length;
        MOBIPdbRecord view = *record; view.data = header;
        MOBIFiletype type = mobi_determine_resource_type(&view);
        if (type == T_BREAK) break;
        if (type == T_UNKNOWN) continue;
        uint32_t size = (uint32_t)record->size;
        if (type == T_FONT) {
            /* The extension depends on the decoded font signature. Inspect one
             * font at a time; never persist a font merely to discover its type. */
            if (gt_mobi_record(s, (uint32_t)i, 2)) continue;
            type = mobi_determine_font_type(s->result, s->result_size);
            if (type == T_UNKNOWN) type = T_TTF;
            size = (uint32_t)s->result_size;
        } else if (type == T_AUDIO || type == T_VIDEO) {
            if (length < 12) continue;
            uint32_t offset = be32(header + 4);
            if (offset > record->size) continue;
            type = type == T_AUDIO ? T_MP3 : T_MPG; size -= offset;
        }
        if (size > 50 * 1024 * 1024) return 4;
        MOBIPart *part = calloc(1, sizeof(*part));
        if (!part) return 5;
        part->uid = i - first; part->type = type; part->size = size;
        *tail = part; tail = &part->next;
        if (!entry_add(b, part, 2, "resource")) return 4;
    }
    return 0;
}

int gt_book_structure(gt_mobi_book *b) {
    if (b->raw) return 1;
    gt_mobi_session *s = b->session;
    /* Dictionaries and legacy encodings keep their existing compatible reader
     * until their distinct coordinate conversions have an equivalent recipe. */
    if (mobi_is_cp1252(s->m) || mobi_is_dictionary(s->m)) return 6;
    b->raw = mobi_init_rawml(s->m);
    b->entries = calloc(20000, sizeof(GTEntry));
    if (!b->raw || !b->entries) return 5;
    MOBIRawml *raw = b->raw;
    raw->position_context = b; raw->position_id = gt_position_id;
    const MOBIMobiHeader *h = s->m->mh;
    if (h) {
        int status = load_index(b, &raw->skel, h->skeleton_index);
        if (!status) status = load_index(b, &raw->frag, h->fragment_index);
        if (!status) status = load_index(b, &raw->guide, h->guide_index);
        if (!status) status = load_index(b, &raw->ncx, h->ncx_index);
        if (status) return status;
    }
    if (mobi_exists_fdst(s->m) && h->fdst_section_count && *h->fdst_section_count > 1) {
        size_t number = mobi_get_fdst_record_number(s->m);
        if (gt_load(s, number) || mobi_parse_fdst(s->m, raw) != MOBI_SUCCESS) return 1;
    }
    uint32_t flow_count = raw->fdst ? (uint32_t)raw->fdst->fdst_section_count : 1;
    if (flow_count > 20000) return 4;
    MOBIPart **tail = &raw->flow;
    for (uint32_t i = 0; i < flow_count; i++) {
        uint32_t start = raw->fdst ? raw->fdst->fdst_section_starts[i] : 0;
        uint32_t end = raw->fdst ? raw->fdst->fdst_section_ends[i] : b->text_starts[b->scanned];
        if (end < start || end > b->text_starts[b->scanned]) return 1;
        MOBIPart *part = calloc(1, sizeof(*part));
        if (!part) return 5;
        *tail = part; tail = &part->next;
        part->uid = i; part->size = end - start;
        part->type = i == 0 || raw->version < 8 ? T_HTML : T_UNKNOWN;
        if (i) {
            GTEntry *e = entry_add(b, part, 1, "flow");
            if (!e || span_set(e, start, end - start)) return 5;
        }
    }
    b->flow_count = flow_count;
    int status = build_markup(b);
    if (!status) status = build_resources(b);
    if (!status) {
        int gt_flow_types(gt_mobi_book *);
        status = gt_flow_types(b);
    }
    return status;
}
