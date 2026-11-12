import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../data/services/offline_dictionary.dart';
import '../../../core/theme/gt_tokens.dart';
import '../../../core/theme/reading_theme.dart';
import '../../../core/widgets/gt_button.dart';
import 'thought_popover.dart';

Future<void> showDictionaryPopover(
  BuildContext context, {
  required Rect anchor,
  required ReadingTheme theme,
  required String term,
  required List<DictionaryEntry> entries,
  required DictionaryLookup lookup,
  VoidCallback? onPresented,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭查词',
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (context, _, _) {
    final media = MediaQuery.of(context);
    const gutter = GtSpacing.s4;
    const gap = GtSpacing.s3;
    final leftSafe = media.padding.left + gutter;
    final rightSafe = media.size.width - media.padding.right - gutter;
    final topSafe = media.padding.top + gap;
    final bottomSafe =
        media.size.height -
        media.padding.bottom -
        media.viewInsets.bottom -
        gap;
    final width = math.min(360.0, rightSafe - leftSafe);
    final left = (anchor.center.dx - width / 2).clamp(
      leftSafe,
      rightSafe - width,
    );
    final spaceBelow = bottomSafe - anchor.bottom - gap;
    final spaceAbove = anchor.top - gap - topSafe;
    final below = spaceBelow >= 220 || spaceBelow >= spaceAbove;
    final sideHeight = below ? spaceBelow : spaceAbove;
    final safeHeight = bottomSafe - topSafe;
    final useSafeEdge = sideHeight < math.min(180.0, safeHeight * 0.5);
    final height = math.min(
      useSafeEdge ? safeHeight : sideHeight,
      safeHeight * 0.76,
    );
    final tip = (anchor.center.dx - left).clamp(14.0, width - 14);
    return Stack(
      children: [
        Positioned(
          left: left,
          width: width,
          top: below ? (useSafeEdge ? topSafe : anchor.bottom + gap) : null,
          bottom: below
              ? null
              : media.size.height -
                    (useSafeEdge ? bottomSafe : anchor.top - gap),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: ReadingPopoverBubble(
              theme: theme,
              tip: tip,
              below: below,
              child: Padding(
                padding: EdgeInsets.only(
                  top: below ? 8 : 0,
                  bottom: below ? 0 : 8,
                ),
                child: _DictionaryContent(
                  theme: theme,
                  term: term,
                  entries: entries,
                  lookup: lookup,
                  onPresented: onPresented,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  },
);

class _DictionaryContent extends StatefulWidget {
  const _DictionaryContent({
    required this.theme,
    required this.term,
    required this.entries,
    required this.lookup,
    required this.onPresented,
  });

  final ReadingTheme theme;
  final String term;
  final List<DictionaryEntry> entries;
  final DictionaryLookup lookup;
  final VoidCallback? onPresented;

  @override
  State<_DictionaryContent> createState() => _DictionaryContentState();
}

class _DictionaryContentState extends State<_DictionaryContent> {
  static final _han = RegExp(r'^\p{Script=Han}', unicode: true);
  late String _term = widget.term;
  late List<DictionaryEntry> _entries = widget.entries;
  bool _loadingCharacter = false;
  bool _characterError = false;

  @override
  void initState() {
    super.initState();
    final onPresented = widget.onPresented;
    if (onPresented != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onPresented();
      });
    }
  }

  Future<void> _lookupCharacter(String character) async {
    if (_loadingCharacter) return;
    _loadingCharacter = true;
    try {
      final entries = await widget.lookup(character);
      if (!mounted) return;
      setState(() {
        _term = character;
        _entries = entries;
        _characterError = false;
      });
    } on Exception {
      if (mounted) setState(() => _characterError = true);
    } finally {
      _loadingCharacter = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.theme.primary;
    final accent = readingLinkColor(widget.theme);
    final base = TextStyle(color: primary, fontSize: 15, height: 1.55);
    final bySource = <(String, Uri), List<DictionaryEntry>>{};
    for (final entry in _entries) {
      bySource.putIfAbsent((entry.word, entry.source), () => []).add(entry);
    }
    final firstEntry = _entries.firstOrNull;
    final title = firstEntry != null && firstEntry.language == 'zh'
        ? firstEntry.word
        : _term;
    final characters = _term.characters.where(_han.hasMatch).toSet();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        GtSpacing.s4,
        0,
        GtSpacing.s3,
        GtSpacing.s3,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: base.copyWith(
                    fontSize: 24,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: GtButton.icon(
                  tooltip: '关闭查词',
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.close, color: primary, size: 20),
                ),
              ),
            ],
          ),
          Divider(height: 1, color: primary.withValues(alpha: 0.16)),
          Flexible(
            child: SingleChildScrollView(
              key: ValueKey(_term),
              primary: false,
              padding: const EdgeInsets.only(
                top: GtSpacing.s3,
                right: GtSpacing.s1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_entries.isEmpty) ...[
                    Text('词库未收录', style: base),
                    if (characters.isNotEmpty &&
                        (characters.length > 1 || characters.single != _term))
                      Wrap(
                        spacing: GtSpacing.s2,
                        children: [
                          for (final character in characters)
                            GtButton.raw(
                              onPressed: () => _lookupCharacter(character),
                              borderRadius: BorderRadius.circular(
                                GtRadius.control,
                              ),
                              child: SizedBox(
                                width: 48,
                                height: 48,
                                child: Center(
                                  child: Text(
                                    character,
                                    style: base.copyWith(
                                      color: accent,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    if (_characterError) Text('暂时无法查词，请重试', style: base),
                  ],
                  for (final group in bySource.values)
                    _WordDefinitions(
                      term: title,
                      entries: group,
                      base: base,
                      accent: accent,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WordDefinitions extends StatelessWidget {
  const _WordDefinitions({
    required this.term,
    required this.entries,
    required this.base,
    required this.accent,
  });

  final String term;
  final List<DictionaryEntry> entries;
  final TextStyle base;
  final Color accent;

  static const _parts = {
    'noun': '名词',
    'verb': '动词',
    'adj': '形容词',
    'adv': '副词',
    'pron': '代词',
    'prep': '介词',
    'conj': '连词',
    'intj': '感叹词',
    'particle': '助词',
    'classifier': '量词',
    'num': '数词',
    'name': '专名',
    'character': '汉字',
    'phrase': '短语',
    'proverb': '谚语',
    'prefix': '前缀',
    'suffix': '后缀',
    'det': '限定词',
    'article': '冠词',
    'abbrev': '缩写',
    'contraction': '缩约词',
  };

  @override
  Widget build(BuildContext context) {
    final word = entries.first.word;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (word != term)
          Text(
            word,
            style: base.copyWith(fontSize: 19, fontWeight: FontWeight.w700),
          ),
        for (final entry in entries) ...[
          Wrap(
            spacing: GtSpacing.s2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (entry.sounds.isNotEmpty)
                Text(
                  entry.sounds.join('  ·  '),
                  style: base.copyWith(
                    color: accent,
                    fontSize: 15,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              if (_parts[entry.partOfSpeech] case final part?)
                Text(
                  part,
                  style: base.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
          for (final (index, gloss) in entry.glosses.indexed)
            Padding(
              padding: const EdgeInsets.only(top: GtSpacing.s1),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (entry.glosses.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(right: GtSpacing.s2),
                      child: Text(
                        '${index + 1}.',
                        style: base.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  Expanded(child: Text(gloss, style: base)),
                ],
              ),
            ),
          const SizedBox(height: GtSpacing.s2),
        ],
        if (entries.every((entry) => entry.glosses.isEmpty))
          Text('来源词库未提供释义', style: base),
        Align(
          alignment: Alignment.centerLeft,
          child: GtButton.raw(
            onPressed: () => launchUrl(
              entries.first.source,
              mode: LaunchMode.externalApplication,
            ),
            borderRadius: BorderRadius.circular(GtRadius.control),
            child: SizedBox(
              height: 48,
              child: Align(
                widthFactor: 1,
                alignment: Alignment.centerLeft,
                child: Text(
                  entries.first.sourceLabel,
                  style: base.copyWith(color: accent, fontSize: 12),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
