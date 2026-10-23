/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later. */
#ifndef TALETIN_MOBI_EXTRACT_H
#define TALETIN_MOBI_EXTRACT_H
#if defined(_WIN32)
#define GT_EXPORT __declspec(dllexport)
#else
#define GT_EXPORT __attribute__((visibility("default")))
#endif
/* 0 success; 1 invalid; 2 encrypted; 3 unsupported layout;
 * 4 output limit; 5 I/O error. Both paths are UTF-8. */
GT_EXPORT int gt_mobi_extract(const char *source, const char *destination, int *version);
#endif
