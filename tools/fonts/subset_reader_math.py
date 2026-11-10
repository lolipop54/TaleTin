"""从官方 Noto CJK 原字体重建 ReaderMath；不改变符号的字形和度量。

依赖 fonttools==4.66.1。用法：python tools/fonts/subset_reader_math.py 原字体.otf
来源和许可见 assets/fonts/math/SOURCE.md。
"""
import argparse
import hashlib
from pathlib import Path

from fontTools import subset
from fontTools.ttLib import TTFont


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', type=Path, default=Path(
        __file__).resolve().parents[2] / 'assets/fonts/math/ReaderMath.otf')
    args = parser.parse_args()
    source_hash = hashlib.sha256(args.source.read_bytes()).hexdigest()
    if source_hash != '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b':
        parser.error('原字体与已校验来源不一致；请先检查版本和许可')
    font = TTFont(args.source, recalcTimestamp=False)
    # 固定生成日期，使相同工具版本可复现资源字节；不影响绘制。
    font['head'].modified = 3876437942
    options = subset.Options()
    options.layout_features = ['kern']
    options.name_IDs = ['*']
    options.name_legacy = True
    options.name_languages = ['*']
    unicodes = {0xac, 0xb1, 0xd7, 0xf7}
    for first, last in [(0x20, 0x7e), (0x2010, 0x205f), (0x2070, 0x209f),
                        (0x2100, 0x23ff), (0x25a0, 0x27ff), (0x2900, 0x2bff),
                        (0xff00, 0xff65)]:
        unicodes.update(range(first, last + 1))
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=unicodes)
    subsetter.subset(font)
    names = {1: 'ReaderMath', 2: 'Regular', 3: 'ReaderMath-Regular',
             4: 'ReaderMath Regular', 6: 'ReaderMath-Regular',
             16: 'ReaderMath', 17: 'Regular'}
    for record in font['name'].names:
        if record.nameID in names:
            record.string = names[record.nameID].encode(record.getEncoding())
    cff = font['CFF '].cff
    cff.fontNames = ['ReaderMath-Regular']
    cff.topDictIndex[0].FamilyName = 'ReaderMath'
    cff.topDictIndex[0].FullName = 'ReaderMath Regular'
    font.save(args.output)
    print(hashlib.sha256(args.output.read_bytes()).hexdigest())


if __name__ == '__main__':
    main()
