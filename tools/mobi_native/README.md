# MOBI / KF8 native reader

Uses libmobi at commit `906274205c11944b628da1c553b255acb1af7c55` from
https://github.com/bfabiszewski/libmobi (LGPL-3.0-or-later).
The downloaded source ZIP SHA-256 is
`1871781687c66a61b2bb946a88123ce766363a373d69ec558276162336a1c4fb`.

The bundled shared library is built locally by Dart Code Assets and remains
separate from TaleTin's Rust library. Encryption support is disabled. Source,
build instructions, modifications and the license are distributed together.
Replace/rebuild this shared library using the same exported `gt_mobi_extract`
and `gt_mobi_*` direct-reader interfaces; no part of the parser is statically linked into the Flutter binary.

Regenerate bindings with `dart run tool/ffigen.dart <path-to-libclang>`.
Builds support the host C compiler and the Android NDK supplied by Flutter.
The wrapper adds UTF-8 Windows paths, bounded output and a single extraction
entry point. The local change in `third_party/libmobi/src/parse_rawml.c`
starts KF8 anchor searches at a real tag boundary. This prevents quoted
`id` examples in programming books from becoming nonexistent NCX/link targets.

KF8 flow types are indexed in one scan in `util.c` and used by
`mobi_reconstruct_flow` in `parse_rawml.c`. This avoids rescanning the whole HTML
for every stylesheet in a collected edition. The original first-reference,
four-decimal-digit and MIME matching rules remain unchanged; the original
single-part helper is retained for the differential test in
`tools/mobi_perf/flow_types_test.c`.

The direct reader (`src/direct.c`, `book_*.c`) loads record zero, the record
directory and required dictionaries, not every compressed record. Incremental
record scans retain offsets; KF8 skeleton/fragment spans, anchor tables and local
link replacements reconstruct requested entry ranges. A small eight-record cache
bounds retained decoded text. Import-only sequential sessions additionally use a
64 KiB compressed-input window to coalesce small record reads. Record ownership
stays independent of that window. Indexed chapter sessions keep the original
range reads; the window is never serialized. The portable `GTMOBI02` index stores
these recipes,
plus generated OPF/NCX metadata, without body/image/font payloads. Dart adds the
existing segmentation recipes. Per-entry HTML uses the existing Rust DOM and
serializer with the previous Dart URI/media rules; template entries keep Dart's
parser for exact compatibility. Complete outputs are compared byte for byte.

The only additional upstream hook is an optional position lookup callback on
`MOBIRawml`, initialized to NULL for the original extraction path. It allows OPF
and link generation to resolve targets from anchor metadata without loading all
markup. CP1252 and dictionary markup retain the original reader until equivalent
conversion recipes are available. DRM and Print Replica remain unsupported.

Run `test/run_direct_test.ps1` on Windows for complete differential checks over
the 13 local MOBI/AZW3 samples: every text record, reconstructed entry and resource,
index roundtrip, truncated index rejection, and a last-record read that decodes
one record. No book text is printed. FFI uses the pinned ffigen 20.1.1 native
external binding API; this version has no `recordUse`/`recordUseMapping` options.
