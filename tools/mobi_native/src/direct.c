/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
 * Range-backed MOBI I/O. libmobi's normal loader deliberately remains intact:
 * this adapter loads only headers/dictionaries, and one requested record. */
#include "direct.h"
#include "direct_internal.h"
#include "mobi.h"
#include "read.h"
#include "memory.h"
#include "util.h"
#include "compression.h"
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#endif

#define GT_SOURCE_LIMIT ((size_t)200 * 1024 * 1024)
#define GT_RESOURCE_LIMIT ((size_t)50 * 1024 * 1024)
#define GT_TEXT_LIMIT ((size_t)1024 * 1024 * 1024)
#define GT_INPUT_WINDOW ((size_t)64 * 1024)
/* Existing internal parser; declared here rather than changing libmobi API. */
MOBI_RET mobi_parse_record0(MOBIData *m, size_t number);

static FILE *gt_open_source(const char *path) {
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!length) return NULL;
    wchar_t *wide = malloc((size_t)length * sizeof(*wide));
    if (!wide) return NULL;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, length);
    FILE *file = _wfopen(wide, L"rb");
    free(wide);
    return file;
#else
    return fopen(path, "rb");
#endif
}

/* Only metadata records are retained. Large resource/text records use a
 * temporary buffer and are released immediately after processing. */
int gt_load(gt_mobi_session *s, size_t number) {
    if (number >= s->count) return 1;
    MOBIPdbRecord *record = s->records[number];
    if (record->data) return 0;
    if (record->size > GT_RESOURCE_LIMIT) return 4;
    if (s->sequential_input && record->size <= GT_INPUT_WINDOW) {
        if (!s->input_window) {
            s->input_window = malloc(GT_INPUT_WINDOW);
            if (!s->input_window) return 5;
        }
        size_t at = record->offset;
        if (at < s->input_start || at - s->input_start > s->input_size ||
            record->size > s->input_size - (at - s->input_start)) {
            size_t take = s->source_size - at;
            if (take > GT_INPUT_WINDOW) take = GT_INPUT_WINDOW;
            s->input_size = 0;
            if (fseek(s->file, (long)at, SEEK_SET) ||
                fread(s->input_window, 1, take, s->file) != take) return 5;
            s->input_start = at;
            s->input_size = take;
            s->input_fills++;
        }
        // libmobi retains/frees records independently; never give it an alias
        // into the reusable window. Large resources keep the original loader.
        record->data = malloc(record->size ? record->size : 1);
        if (!record->data) return 5;
        memcpy(record->data, s->input_window + at - s->input_start, record->size);
    } else if (mobi_load_recdata(record, s->file) != MOBI_SUCCESS) return 5;
    s->bytes_read += record->size;
    s->retained += record->size;
    return 0;
}

void gt_unload(gt_mobi_session *s, size_t number) {
    MOBIPdbRecord *record = s->records[number];
    if (!record->data) return;
    free(record->data);
    record->data = NULL;
    s->retained -= record->size;
}

void gt_mobi_close(void *pointer) {
    gt_mobi_session *s = pointer;
    if (!s) return;
    gt_book_free(s->book);
    mobi_free_huffcdic(s->huff);
    if (s->m) mobi_free(s->m);
    if (s->file) fclose(s->file);
    free(s->records);
    free(s->input_window);
    free(s->result);
    free(s);
}

void gt_mobi_buffer_input(gt_mobi_session *s) { if (s) s->sequential_input = 1; }

gt_mobi_session *gt_mobi_open(const char *source, int *status) {
    *status = 1;
    gt_mobi_session *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->file = gt_open_source(source);
    if (!s->file) { *status = 5; goto failed; }
    if (fseek(s->file, 0, SEEK_END)) goto failed;
    long size = ftell(s->file);
    if (size < 78 || (size_t)size > GT_SOURCE_LIMIT) {
        *status = size > 0 ? 4 : 1;
        goto failed;
    }
    s->source_size = (size_t)size;
    rewind(s->file);
    s->m = mobi_init();
    if (!s->m || mobi_load_pdbheader(s->m, s->file) != MOBI_SUCCESS) goto failed;
    if ((strcmp(s->m->ph->type, "BOOK") && strcmp(s->m->ph->type, "TEXt")) ||
        !s->m->ph->rec_count ||
        mobi_load_reclist(s->m, s->file) != MOBI_SUCCESS) goto failed;
    s->count = s->m->ph->rec_count;
    s->bytes_read = 78 + s->count * 8;
    s->records = calloc(s->count, sizeof(*s->records));
    if (!s->records) goto failed;
    MOBIPdbRecord *record = s->m->rec;
    size_t minimum = 78 + s->count * 8;
    for (size_t i = 0; i < s->count; i++, record = record->next) {
        size_t end = record->next ? record->next->offset : s->source_size;
        if (record->offset < minimum || end < record->offset || end > s->source_size) goto failed;
        record->size = end - record->offset;
        minimum = end;
        s->records[i] = record;
    }
    if (gt_load(s, 0) || mobi_parse_record0(s->m, 0) != MOBI_SUCCESS) goto failed;
    /* libmobi validates EXTH 121 by inspecting the boundary record's magic.
     * Its full loader has already loaded that record; our lazy loader has not. */
    const MOBIExthHeader *boundary_tag = mobi_get_exthrecord_by_tag(s->m, EXTH_KF8BOUNDARY);
    if (boundary_tag) {
        uint32_t candidate = mobi_decode_exthvalue(boundary_tag->data, boundary_tag->size);
        if (candidate && candidate - 1 < s->count && gt_load(s, candidate - 1)) goto failed;
    }
    size_t boundary = mobi_get_kf8boundary_seqnumber(s->m);
    if (boundary != MOBI_NOTSET && boundary < UINT32_MAX) {
        if (boundary >= s->count - 1 || gt_load(s, boundary + 1)) goto failed;
        MOBIData *m = s->m;
        m->kf8_boundary_offset = (uint32_t)boundary;
        m->next = mobi_init();
        if (!m->next) goto failed;
        m->next->ph = m->ph;
        m->next->rec = m->rec;
        m->next->internals = m->internals;
        m->next->next = m;
        if (mobi_parse_record0(m->next, boundary + 1) != MOBI_SUCCESS) goto failed;
        if (m->use_kf8) mobi_swap_mobidata(m);
    }
    if (mobi_is_encrypted(s->m)) { *status = 2; goto failed; }
    if (!s->m->rh || mobi_get_text_maxsize(s->m) > GT_TEXT_LIMIT) {
        *status = 4; goto failed;
    }
    s->first_text = 1 + mobi_get_kf8offset(s->m);
    s->text_count = s->m->rh->text_record_count;
    s->resource_first = mobi_get_first_resource_record(s->m);
    if (s->resource_first == MOBI_NOTSET) s->resource_first = 0;
    if (!s->text_count || s->first_text >= s->count ||
        s->text_count > s->count - s->first_text) goto failed;
    if (s->m->rh->compression_type == MOBI_COMPRESSION_NONE) {
        /* The replica signature is in the first text record, not record zero. */
        if (gt_load(s, s->first_text)) goto failed;
        MOBIPdbRecord *first = s->records[s->first_text];
        int replica = first->size >= 4 && !memcmp(first->data, "%MOP", 4);
        gt_unload(s, s->first_text);
        if (replica) { *status = 3; goto failed; }
    }
    if (s->m->rh->compression_type == MOBI_COMPRESSION_HUFFCDIC) {
        const MOBIMobiHeader *header = s->m->mh;
        if (!header || !header->huff_rec_index || !header->huff_rec_count) goto failed;
        size_t first = *header->huff_rec_index + mobi_get_kf8offset(s->m);
        size_t count = *header->huff_rec_count;
        if (first >= s->count || count < 2 || count > s->count - first ||
            count > HUFF_RECORD_MAXCNT) goto failed;
        for (size_t i = 0; i < count; i++) if (gt_load(s, first + i)) goto failed;
        s->huff = mobi_init_huffcdic();
        if (!s->huff || mobi_parse_huffdic(s->m, s->huff) != MOBI_SUCCESS) goto failed;
    }
    *status = 0;
    return s;
failed:
    gt_mobi_close(s);
    return NULL;
}

uint64_t gt_mobi_info(gt_mobi_session *s, int field) {
    if (!s) return 0;
    switch (field) {
        case 0: return s->count;
        case 1: return s->first_text;
        case 2: return s->text_count;
        case 3: return s->resource_first;
        case 4: return mobi_get_fileversion(s->m);
        case 5: return s->m->mh && s->m->mh->text_encoding ? *s->m->mh->text_encoding : 1252;
        case 6: return s->source_size;
        case 7: return s->bytes_read;
        case 8: return s->decoded_count;
        case 9: return s->retained;
        case 10: return mobi_get_textrecord_maxsize(s->m);
        case 11: return s->input_fills;
        case 12: return s->input_window ? GT_INPUT_WINDOW : 0;
        default: return 0;
    }
}

int gt_mobi_record(gt_mobi_session *s, uint32_t number, int mode) {
    if (!s || number >= s->count || mode < 0 || mode > 2) return 1;
    /* Never evict the current output before validating the request. */
    if (mode == 1 && (number < s->first_text || number - s->first_text >= s->text_count)) return 1;
    MOBIPdbRecord *record = s->records[number];
    int retained = record->data != NULL;
    int status = gt_load(s, number);
    if (status) return status;
    unsigned char *output = NULL;
    size_t length = 0;
    if (mode == 1) {
        size_t extra = s->m->mh && s->m->mh->extra_flags
            ? mobi_get_record_extrasize(record, *s->m->mh->extra_flags) : 0;
        if (extra == MOBI_NOTSET || extra > record->size) { status = 1; goto done; }
        size_t input_size = record->size - extra;
        length = mobi_get_textrecord_maxsize(s->m);
        if (!length || length > GT_RESOURCE_LIMIT) { status = 4; goto done; }
        output = malloc(length);
        if (!output) { status = 5; goto done; }
        MOBI_RET result = MOBI_SUCCESS;
        if (!input_size) length = 0;
        else switch (s->m->rh->compression_type) {
            case MOBI_COMPRESSION_NONE:
                if (input_size > length) { status = 4; goto done; }
                memcpy(output, record->data, input_size);
                length = input_size;
                if (mobi_exists_mobiheader(s->m) && mobi_get_fileversion(s->m) <= 3)
                    mobi_remove_zeros(output, &length);
                break;
            case MOBI_COMPRESSION_PALMDOC:
                result = mobi_decompress_lz77(output, record->data, &length, input_size);
                break;
            case MOBI_COMPRESSION_HUFFCDIC:
                result = mobi_decompress_huffman(output, record->data, &length, input_size, s->huff);
                break;
            default: status = 1;
        }
        if (result != MOBI_SUCCESS) status = 1;
        if (!status) s->decoded_count++;
    } else if (mode == 2) {
        MOBIPart part = {0};
        part.data = record->data;
        part.size = record->size;
        part.type = mobi_determine_resource_type(record);
        MOBI_RET result = MOBI_SUCCESS;
        if (part.type == T_FONT) {
            if (part.size >= 8) {
                uint32_t declared = (uint32_t)part.data[4] << 24 | (uint32_t)part.data[5] << 16 |
                                    (uint32_t)part.data[6] << 8 | part.data[7];
                if (declared > GT_RESOURCE_LIMIT) { status = 4; goto done; }
            }
            result = mobi_decode_font_resource(&output, &length, &part);
            /* libmobi frees its allocation on font decoding failure. */
            if (result != MOBI_SUCCESS) output = NULL;
        } else if (part.type == T_AUDIO || part.type == T_VIDEO) {
            unsigned char *alias = NULL;
            result = part.type == T_AUDIO
                ? mobi_decode_audio_resource(&alias, &length, &part)
                : mobi_decode_video_resource(&alias, &length, &part);
            /* Audio/video decoders return a view into the compressed record. */
            if (result == MOBI_SUCCESS) {
                output = malloc(length ? length : 1);
                if (output) memcpy(output, alias, length);
            }
        } else {
            length = record->size;
            output = malloc(length ? length : 1);
            if (output) memcpy(output, record->data, length);
        }
        if (result != MOBI_SUCCESS) status = 1;
    } else {
        length = record->size;
        output = malloc(length ? length : 1);
        if (output) memcpy(output, record->data, length);
    }
    if (!output && !status) status = 5;
    if (length > GT_RESOURCE_LIMIT) status = 4;
done:
    if (!retained) gt_unload(s, number);
    if (status) { free(output); return status; }
    free(s->result);
    s->result = output;
    s->result_size = length;
    return 0;
}

const unsigned char *gt_mobi_result(gt_mobi_session *s) { return s ? s->result : NULL; }
size_t gt_mobi_result_size(gt_mobi_session *s) { return s ? s->result_size : 0; }
uint64_t gt_mobi_record_offset(gt_mobi_session *s, uint32_t n) {
    return s && n < s->count ? s->records[n]->offset : UINT64_MAX;
}
uint64_t gt_mobi_record_size(gt_mobi_session *s, uint32_t n) {
    return s && n < s->count ? s->records[n]->size : UINT64_MAX;
}
