/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
 * Scan bounded windows/tags, retaining only anchors and local replacements. */
#include "book_internal.h"
#include "index.h"
#include "util.h"
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

MOBI_RET mobi_get_offset_by_posoff(uint32_t *, size_t *, const MOBIRawml *, size_t, size_t);
size_t mobi_get_attribute_value(char *, const unsigned char *, size_t, const char *, bool);
MOBI_RET mobi_search_links_kf7(MOBIResult *, const unsigned char *, const unsigned char *);
MOBI_RET mobi_search_links_kf8(MOBIResult *, const unsigned char *, const unsigned char *, MOBIFiletype);
MOBI_RET mobi_find_attrname(MOBIResult *, const unsigned char *, const unsigned char *, const char *);
MOBI_RET mobi_posfid_to_link(char *, const MOBIRawml *, const char *, MOBIAttrType *);
MOBI_RET mobi_flow_to_link(char *, const MOBIRawml *, const char *);
MOBI_RET mobi_embed_to_link(char *, const MOBIRawml *, const char *);

int gt_walk_tags(gt_mobi_book *b, GTEntry *e, GTTagCallback callback, void *context) {
    unsigned char chunk[32768];
    unsigned char *tag = NULL;
    uint32_t tag_size = 0, capacity = 0, tag_at = 0;
    int in_tag = 0, status = 0;
    for (uint32_t at = 0; at < e->meta->size && !status;) {
        uint32_t take = (uint32_t)e->meta->size - at;
        if (take > sizeof(chunk)) take = sizeof(chunk);
        status = gt_entry_into(b, e, at, take, chunk);
        if (status) break;
        for (uint32_t i = 0; i < take && !status; i++) {
            unsigned char c = chunk[i];
            if (c == '<') { in_tag = 1; tag_size = 0; tag_at = at + i; }
            if (!in_tag) continue;
            if (tag_size == capacity) {
                uint32_t next = capacity ? capacity * 2 : 1024;
                if (next > 50 * 1024 * 1024) { status = 4; break; }
                unsigned char *grown = realloc(tag, next);
                if (!grown) { status = 5; break; }
                tag = grown; capacity = next;
            }
            tag[tag_size++] = c;
            if (c == '>') {
                status = callback(b, e, tag, tag_size, tag_at, context);
                in_tag = 0;
            }
        }
        at += take;
    }
    /* The original parser also searches an unterminated final tag. */
    if (!status && in_tag && tag_size) status = callback(b, e, tag, tag_size, tag_at, context);
    free(tag);
    return status;
}

static int anchor_tag(gt_mobi_book *b, GTEntry *e, const unsigned char *data,
                      uint32_t length, uint32_t at, void *context) {
    (void)b; (void)context;
    for (uint32_t kind = 0; kind < 2; kind++) {
        char value[151];
        size_t found = mobi_get_attribute_value(value, data, length, kind ? "name" : "id", true);
        if (found == SIZE_MAX) continue;
        GTAnchor *grown = realloc(e->anchors, (e->anchor_count + 1) * sizeof(GTAnchor));
        if (!grown) return 5;
        e->anchors = grown;
        GTAnchor *anchor = &grown[e->anchor_count++];
        anchor->tag = at; anchor->end = at + length - 1; anchor->kind = kind;
        anchor->value = malloc(strlen(value) + 1);
        if (!anchor->value) return 5;
        strcpy(anchor->value, value);
    }
    return 0;
}

int gt_entry_anchors(gt_mobi_book *b, GTEntry *e) {
    if (e->kind != 0) return 0;
    if (e->anchor_count) return 1;
    return gt_walk_tags(b, e, anchor_tag, NULL);
}

MOBI_RET gt_position_id(const void *context, uint32_t *number, char *id,
                       size_t fid, size_t offset, int *preferred) {
    const gt_mobi_book *b = context;
    size_t at;
    MOBI_RET status = mobi_get_offset_by_posoff(number, &at, b->raw, fid, offset);
    if (status != MOBI_SUCCESS) return status;
    const GTEntry *e = NULL;
    for (uint32_t i = 0; i < b->entry_count; i++) {
        if (b->entries[i].kind == 0 && b->entries[i].meta->uid == *number) { e = &b->entries[i]; break; }
    }
    if (!e || at > e->meta->size) return MOBI_DATA_CORRUPT;
    id[0] = 0;
    for (int attempt = 0; attempt < 2; attempt++) {
        int kind = attempt ? 1 - *preferred : *preferred;
        for (uint32_t i = 0; i < e->anchor_count; i++) {
            GTAnchor *a = &e->anchors[i];
            if (a->end < at || a->kind != (uint32_t)kind) continue;
            strcpy(id, a->value); *preferred = kind;
            return MOBI_SUCCESS;
        }
    }
    return MOBI_SUCCESS;
}

typedef struct { unsigned char seen[10000]; } GTFlowTypes;
static int flow_tag(gt_mobi_book *b, GTEntry *e, const unsigned char *data,
                    uint32_t length, uint32_t at, void *context) {
    (void)e; (void)at;
    GTFlowTypes *types = context;
    const char prefix[] = "\"kindle:flow:";
    for (uint32_t i = 0; i + sizeof(prefix) - 1 + 10 <= length; i++) {
        if (memcmp(data + i, prefix, sizeof(prefix) - 1)) continue;
        const unsigned char *digits = data + i + sizeof(prefix) - 1;
        uint32_t number = 0; int valid = 1;
        for (int j = 0; j < 4; j++) {
            if (digits[j] < '0' || digits[j] > '9') { valid = 0; break; }
            number = number * 10 + digits[j] - '0';
        }
        if (!valid || types->seen[number] || memcmp(digits + 4, "?mime=", 6)) continue;
        char target[32]; snprintf(target, sizeof(target), "\"kindle:flow:%04u?mime=", number);
        MOBIResult result;
        if (mobi_find_attrvalue(&result, data, data + length - 1, T_HTML, target) != MOBI_SUCCESS || !result.start) continue;
        types->seen[number] = 1;
        MOBIPart *flow = b->raw->flow;
        while (flow && flow->uid != number) flow = flow->next;
        if (!flow || !number) continue;
        if (strstr(result.value, "text/css")) flow->type = T_CSS;
        else if (strstr(result.value, "image/svg+xml")) flow->type = T_SVG;
    }
    return 0;
}

int gt_flow_types(gt_mobi_book *b) {
    if (!mobi_is_rawml_kf8(b->raw) || b->flow_count <= 1) return 0;
    GTEntry source = {0};
    GTSpan span = {b->raw->fdst ? b->raw->fdst->fdst_section_starts[0] : 0,
                   (uint32_t)b->raw->flow->size};
    source.meta = b->raw->flow; source.spans = &span; source.span_count = 1;
    GTFlowTypes *types = calloc(1, sizeof(*types));
    if (!types) return 5;
    int status = gt_walk_tags(b, &source, flow_tag, types);
    free(types);
    for (uint32_t i = 0; i < b->entry_count; i++) {
        GTEntry *e = &b->entries[i];
        if (e->kind == 1) snprintf(e->name, sizeof(e->name), "flow%05zu.%s", e->meta->uid,
            mobi_get_filemeta_by_type(e->meta->type).extension);
    }
    return status;
}

static int patch_add(GTEntry *e, uint32_t at, uint32_t removed, const char *value, uint32_t length) {
    if (at > e->meta->size || removed > e->meta->size - at) return 1;
    GTPatch *grown = realloc(e->patches, (e->patch_count + 1) * sizeof(GTPatch));
    if (!grown) return 5;
    e->patches = grown;
    GTPatch *p = &grown[e->patch_count++];
    p->offset = at; p->removed = removed; p->length = length;
    p->data = malloc(length ? length : 1);
    if (!p->data) return 5;
    memcpy(p->data, value, length);
    return 0;
}

typedef struct { MOBIAttrType preferred; uint32_t *targets; uint32_t count; } GTLinkContext;
static int add_target(GTLinkContext *context, uint32_t value) {
    uint32_t *grown = realloc(context->targets, (context->count + 1) * sizeof(uint32_t));
    if (!grown) return 5;
    context->targets = grown; grown[context->count++] = value;
    return 0;
}

static int link_tag(gt_mobi_book *b, GTEntry *e, const unsigned char *data,
                    uint32_t length, uint32_t at, void *opaque) {
    GTLinkContext *context = opaque;
    int kf8 = mobi_is_rawml_kf8(b->raw);
    if (!kf8) {
        char value[151];
        size_t cursor = 0, found;
        while (cursor < length && (found = mobi_get_attribute_value(value,
                data + cursor, length - cursor, "filepos", false)) != SIZE_MAX) {
            unsigned long target = strtoul(value, NULL, 10);
            if (target && target <= UINT32_MAX && add_target(context, (uint32_t)target)) return 5;
            cursor += found;
        }
    }
    /* aid is stripped after link rewriting. Retain lookup effects, but omit a
     * replacement wholly covered by the later aid deletion. */
    MOBIResult aid = {0};
    if (kf8 && e->meta->type == T_HTML) mobi_find_attrname(&aid, data, data + length - 1, "aid");
    const unsigned char *cursor = data, *end = data + length - 1;
    while (cursor <= end) {
        MOBIResult result;
        MOBI_RET status = kf8 ? mobi_search_links_kf8(&result, cursor, end, e->meta->type)
                             : mobi_search_links_kf7(&result, cursor, end);
        if (status != MOBI_SUCCESS) return 1;
        if (!result.start) break;
        const unsigned char *start = result.start;
        char link[151] = {0}; char *target;
        if (kf8) {
            if ((target = strstr(result.value, "kindle:pos:fid:"))) status = mobi_posfid_to_link(link, b->raw, target, &context->preferred);
            else if ((target = strstr(result.value, "kindle:flow:"))) status = mobi_flow_to_link(link, b->raw, target);
            else if ((target = strstr(result.value, "kindle:embed:"))) status = mobi_embed_to_link(link, b->raw, target);
        } else {
            char *numbers = strpbrk(result.value, "0123456789");
            if (numbers) {
                uint32_t number = (uint32_t)strtoul(numbers, NULL, 10);
                switch (result.value[0]) {
                    case 'f': snprintf(link, sizeof(link), "href=\"#%010u\"", number); break;
                    case 'h': case 'l': start += 2; /* preserve hi/lo prefix like libmobi */
                    case 'r':
                        if (number) number--;
                        snprintf(link, sizeof(link), "src=\"resource%05u.%s\"", number,
                            mobi_get_filemeta_by_type(mobi_get_resourcetype_by_uid(b->raw, number)).extension);
                        break;
                }
            }
        }
        if (status != MOBI_SUCCESS) return 1;
        if (link[0] && !(aid.start && start >= aid.start && result.end <= aid.end)) {
            uint32_t trim = kf8 && result.is_url ? 1 : 0;
            int error = patch_add(e, at + (uint32_t)(start - data), (uint32_t)(result.end - start),
                                  link + trim, (uint32_t)strlen(link) - 2 * trim);
            if (error) return error;
        }
        cursor = result.end;
    }
    if (aid.start) return patch_add(e, at + (uint32_t)(aid.start - data), (uint32_t)(aid.end - aid.start), "", 0);
    return 0;
}

static int compare_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return x < y ? -1 : x > y;
}
static int compare_patch(const void *a, const void *b) {
    const GTPatch *x = a, *y = b;
    if (x->offset != y->offset) return x->offset < y->offset ? -1 : 1;
    return x->removed < y->removed ? -1 : x->removed > y->removed;
}

int gt_entry_patch(gt_mobi_book *b, GTEntry *e) {
    if (!e->meta->size) return 0;
    if (e->kind != 0 && e->kind != 1) return 0;
    if (e->patch_count) return 1;
    GTLinkContext context = {0};
    int status;
    if (e->meta->type != T_CSS) status = gt_walk_tags(b, e, link_tag, &context);
    else {
        /* CSS uses braces, not HTML tags. A flow is an individual stylesheet
         * with the existing 50 MiB entry limit; it is released after scanning. */
        if (e->meta->size > 50 * 1024 * 1024) return 4;
        unsigned char *css = malloc(e->meta->size + 1);
        if (!css) return 5;
        status = gt_entry_into(b, e, 0, (uint32_t)e->meta->size, css);
        if (!status) status = link_tag(b, e, css, (uint32_t)e->meta->size, 0, &context);
        free(css);
    }
    if (!status && !mobi_is_rawml_kf8(b->raw)) {
        for (MOBIPart *part = b->raw->resources; part; part = part->next) {
            if (part->type != T_NCX) continue;
            size_t at = 0;
            while (at < part->size) {
                char value[151];
                size_t found = mobi_get_attribute_value(value, part->data + at, part->size - at, "src", false);
                if (found == SIZE_MAX) break;
                uint32_t target = 0;
                if (strlen(value) >= 15) sscanf(value + 15, "%10u", &target);
                if (add_target(&context, target)) { status = 5; break; }
                at += found;
            }
        }
        qsort(context.targets, context.count, sizeof(uint32_t), compare_u32);
        for (uint32_t i = 0; i < context.count && !status; i++) {
            uint32_t target = context.targets[i];
            if (i && target == context.targets[i - 1]) continue;
            int removed = target > e->meta->size;
            for (uint32_t j = 0; j < e->patch_count && !removed; j++) {
                GTPatch *p = &e->patches[j];
                if (p->offset < target && p->removed > target - p->offset) removed = 1;
            }
            if (removed) continue;
            char anchor[64]; int size = snprintf(anchor, sizeof(anchor), "<a id=\"%010u\"></a>", target);
            status = patch_add(e, target, 0, anchor, (uint32_t)size);
        }
    }
    free(context.targets);
    if (status) return status;
    qsort(e->patches, e->patch_count, sizeof(GTPatch), compare_patch);
    uint32_t raw_at = 0, output_at = 0;
    uint64_t size = e->meta->size;
    for (uint32_t i = 0; i < e->patch_count; i++) {
        GTPatch *p = &e->patches[i];
        if (p->offset < raw_at) return 1;
        output_at += p->offset - raw_at + p->length;
        p->output_end = output_at;
        raw_at = p->offset + p->removed;
        size = size - p->removed + p->length;
    }
    if (size > 1024 * 1024 * 1024) return 4;
    e->output_size = (uint32_t)size;
    return 0;
}
