/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
 * libmobi owns all parsed buffers; this synchronous call releases them on
 * every exit before returning to the cancellable Dart worker. */
#include "extract.h"
#include "mobi.h"
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#endif

#define MAX_ENTRY ((size_t)50 * 1024 * 1024)
#define MAX_TOTAL ((size_t)1024 * 1024 * 1024)
#define MAX_ENTRIES 20000

static FILE *open_utf8(const char *path, int writing) {
#ifdef _WIN32
    int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, NULL, 0);
    if (!size) return NULL;
    wchar_t *wide = malloc((size_t)size * sizeof(wchar_t));
    if (!wide) return NULL;
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide, size);
    FILE *file = _wfopen(wide, writing ? L"wb" : L"rb");
    free(wide);
    return file;
#else
    return fopen(path, writing ? "wb" : "rb");
#endif
}

static int write_parts(const MOBIPart *part, const char *prefix,
                       const char *destination, size_t *count, size_t *total) {
    while (part) {
        if (part->size) {
            if (++*count > MAX_ENTRIES || (part->type != T_HTML && part->size > MAX_ENTRY) ||
                part->size > MAX_TOTAL - *total) return 4;
            *total += part->size;
            MOBIFileMeta meta = mobi_get_filemeta_by_type(part->type);
            /* All output names come from our numeric ids and libmobi's fixed
             * extension table, never from book-controlled paths. */
            char name[80];
            if (part->type == T_OPF) strcpy(name, "content.opf");
            else snprintf(name, sizeof(name), "%s%05zu.%s", prefix, part->uid, meta.extension);
            size_t length = strlen(destination) + strlen(name) + 2;
            char *path = malloc(length);
            if (!path) return 5;
            snprintf(path, length, "%s/%s", destination, name);
            FILE *out = open_utf8(path, 1);
            free(path);
            if (!out) return 5;
            size_t written = fwrite(part->data, 1, part->size, out);
            int closed = fclose(out);
            if (written != part->size || closed) return 5;
        }
        part = part->next;
    }
    return 0;
}

int gt_mobi_extract(const char *source, const char *destination, int *version) {
    MOBIData *m = mobi_init();
    MOBIRawml *raw = NULL;
    int result = 1;
    if (!m) return result;
    FILE *file = open_utf8(source, 0);
    if (!file) { mobi_free(m); return 5; }
    MOBI_RET loaded = mobi_load_file(m, file);
    fclose(file);
    if (loaded != MOBI_SUCCESS) goto done;
    if (mobi_is_encrypted(m)) { result = 2; goto done; }
    if (mobi_is_replica(m)) { result = 3; goto done; }
    if (mobi_get_text_maxsize(m) > MAX_TOTAL) { result = 4; goto done; }
    raw = mobi_init_rawml(m);
    if (!raw || mobi_parse_rawml(raw, m) != MOBI_SUCCESS) goto done;
    *version = (int)raw->version;
    size_t count = 0, total = 0;
    result = write_parts(raw->markup, "part", destination, &count, &total);
    if (!result && raw->flow)
        result = write_parts(raw->flow->next, "flow", destination, &count, &total);
    if (!result)
        result = write_parts(raw->resources, "resource", destination, &count, &total);
done:
    if (raw) mobi_free_rawml(raw);
    mobi_free(m);
    return result;
}
