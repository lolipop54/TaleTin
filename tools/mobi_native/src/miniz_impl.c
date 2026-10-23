/* Copyright (c) 2026 TaleTin contributors. LGPL-3.0-or-later.
 * The included miniz implementation is public domain (see its final notice).
 * Match libmobi's miniz.h without redefining macros for every source file. */
#define MINIZ_NO_STDIO
#define MINIZ_NO_ZLIB_COMPATIBLE_NAMES
#define MINIZ_NO_TIME
#define MINIZ_NO_ARCHIVE_APIS
#define MINIZ_NO_ARCHIVE_WRITING_APIS
#include "../third_party/libmobi/src/miniz.c"
