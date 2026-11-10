ReaderMath: symbol subset of Noto Sans CJK SC Regular

- Upstream: https://github.com/notofonts/noto-cjk
- Source: https://github.com/notofonts/noto-cjk/blob/main/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf
- Downloaded 2026-11-02; verified Git blob dc15562470b4f842321894787a0d066879ccff8b. Source SHA-256: 2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b.
- Subset contains 520 glyphs / 536 code points: available ASCII, common mathematical operators, arrows, geometric symbols, punctuation and fullwidth variants. CJK text glyphs are excluded.
- Generated with fontTools.subset; retained kerning, copyright and license records; renamed family and CFF names to ReaderMath. Glyph outlines, advances and vertical metrics are unchanged.
- Rebuild with fonttools 4.66.1: `python tools/fonts/subset_reader_math.py /path/to/NotoSansCJKsc-Regular.otf`. The script checks the source hash and fixes the generated timestamp for reproducibility.
- ReaderMath.otf: 60,580 bytes; SHA-256 871a8654892ee601a6f457779d26d7171f826145ff07657b591f8892b7d0ec48.
- License: assets/licenses/ReaderMath-OFL.txt (SIL OFL 1.1), copied from upstream Sans/LICENSE, verified Git blob d952d62c065f3f35fb83a173496e90b21525aef3.

Used for MathML operators and for selected arrows and geometric symbols that need a monochrome text glyph in simplified layout. This engine asset remains in packages without optional preset reading fonts. Unsupported symbols retain platform font fallback.
