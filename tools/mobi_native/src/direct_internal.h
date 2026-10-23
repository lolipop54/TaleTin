/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later. */
#ifndef TALETIN_MOBI_DIRECT_INTERNAL_H
#define TALETIN_MOBI_DIRECT_INTERNAL_H
#include "direct.h"
#include "mobi.h"
#include "compression.h"

typedef struct gt_mobi_book gt_mobi_book;
struct gt_mobi_session {
    FILE *file;
    MOBIData *m;
    MOBIPdbRecord **records;
    MOBIHuffCdic *huff;
    unsigned char *result;
    size_t result_size;
    size_t source_size, count, first_text, text_count, resource_first;
    uint64_t bytes_read, decoded_count, retained;
    unsigned char *input_window;
    size_t input_start, input_size;
    uint64_t input_fills;
    int sequential_input;
    gt_mobi_book *book;
};

int gt_load(gt_mobi_session *s, size_t number);
void gt_unload(gt_mobi_session *s, size_t number);
void gt_book_free(gt_mobi_book *book);
#endif
