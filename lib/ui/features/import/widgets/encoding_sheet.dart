import 'package:taletin/ui/core/widgets/gt_button.dart';
import 'package:flutter/material.dart';


import '../../../../domain/services/text_preparation.dart';
import '../../../../domain/use_cases/import_books.dart';
import '../../../../engine/parsers/txt/txt_chapter_rule.dart';
import '../view_models/import_view_model.dart';

/// 编码预览面板：确认 TXT 编码与章节识别规则后再开始导入。
///
/// 设计文档 6.3：提供编码预览和手动切换、允许修改规则后重新解析。
/// 自动识别高置信（BOM / 严格 UTF-8）的文件不会弹这个面板。
class EncodingSheet extends StatefulWidget {
  const EncodingSheet({
    super.key,
    required this.items,
    required this.preparation,
  });

  final List<ImportItem> items;
  final TextPreparationService preparation;

  /// 弹出面板；用户取消时返回 null。
  static Future<Map<String, TxtImportChoice>?> show(
    BuildContext context, {
    required List<ImportItem> items,
    required TextPreparationService preparation,
  }) {
    return showModalBottomSheet<Map<String, TxtImportChoice>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EncodingSheet(items: items, preparation: preparation),
    );
  }

  @override
  State<EncodingSheet> createState() => _EncodingSheetState();
}

class _EncodingSheetState extends State<EncodingSheet> {
  /// 当前预览的文件
  late ImportItem _current = widget.items.first;

  /// 每个文件选定的编码
  late final Map<String, String> _charsets = {
    for (final item in widget.items) item.key: item.charset ?? kFallbackCharsetName,
  };

  /// 章节规则：自动识别 / 按长度分段 / 自定义正则
  _ChapterMode _chapterMode = _ChapterMode.auto;
  final TextEditingController _pattern = TextEditingController();
  String? _patternError;

  List<String> _available = const [];
  String _preview = '';
  bool _previewLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCharsets();
    _loadPreview();
  }

  @override
  void dispose() {
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _loadCharsets() async {
    try {
      final list = await widget.preparation.supportedCharsets();
      if (!mounted) return;
      setState(() => _available = list);
    } catch (_) {
      // 平台取不到列表时只保留已识别编码，不影响确认
    }
  }

  Future<void> _loadPreview() async {
    setState(() => _previewLoading = true);
    final sample = _current.sample;
    final charset = _charsets[_current.key]!;
    if (sample == null) {
      setState(() {
        _preview = '';
        _previewLoading = false;
      });
      return;
    }
    try {
      final text = await widget.preparation.preview(
        bytes: sample,
        charset: charset,
      );
      if (!mounted) return;
      setState(() {
        _preview = text.replaceAll(RegExp(r'\s+\n'), '\n').trim();
        _previewLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _preview = '无法用 $charset 解码该文件：$error';
        _previewLoading = false;
      });
    }
  }

  void _selectCharset(String charset) {
    setState(() => _charsets[_current.key] = charset);
    _loadPreview();
  }

  void _confirm() {
    if (_chapterMode == _ChapterMode.custom) {
      final pattern = _pattern.text.trim();
      if (pattern.isEmpty) {
        setState(() => _patternError = '请输入章节标题正则');
        return;
      }
      if (!TxtChapterRule.compileCustom(pattern)) {
        setState(() => _patternError = '正则无效或过于复杂');
        return;
      }
    }
    Navigator.of(context).pop({
      for (final item in widget.items)
        item.key: TxtImportChoice(
          charset: _charsets[item.key],
          chapterPattern:
              _chapterMode == _ChapterMode.custom ? _pattern.text.trim() : null,
          forceSectionFallback: _chapterMode == _ChapterMode.sections,
        ),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: _panel(context),
    );
  }

  Widget _panel(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF7F3EA),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('编码与章节规则',
                  style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF20242B))),
              const SizedBox(height: 8),
              const Text(
                '自动识别的编码不确定，请对照下面的预览确认；确认后按此编码导入。',
                style: TextStyle(fontSize: 13, color: Color(0xFF596270)),
              ),
              const SizedBox(height: 16),
              if (widget.items.length > 1) _fileSelector(),
              _charsetSelector(),
              const SizedBox(height: 16),
              _previewBox(),
              const SizedBox(height: 16),
              _chapterRule(),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: GtButton.outlined(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: GtButton.filled(
                      onPressed: _confirm,
                      child: const Text('开始导入'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fileSelector() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final item in widget.items)
            ChoiceChip(
              label: Text(
                item.document.name,
                overflow: TextOverflow.ellipsis,
              ),
              selected: item.key == _current.key,
              onSelected: (_) {
                setState(() => _current = item);
                _loadPreview();
              },
            ),
        ],
      ),
    );
  }

  Widget _charsetSelector() {
    final selected = _charsets[_current.key]!;
    final options = <String>{
      selected,
      if (_current.charset != null) _current.charset!,
      ..._available,
    }.toList();
    return Row(
      children: [
        const Text('编码',
            style: TextStyle(fontSize: 15, color: Color(0xFF20242B))),
        const SizedBox(width: 12),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: selected,
            isExpanded: true,
            items: [
              for (final name in options)
                DropdownMenuItem(value: name, child: Text(name)),
            ],
            onChanged: (value) {
              if (value != null) _selectCharset(value);
            },
          ),
        ),
      ],
    );
  }

  Widget _previewBox() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE3E7ED)),
      ),
      child: _previewLoading
          ? const Center(
              child: SizedBox(
                width: 40,
                height: 40,
                child: SizedBox.shrink(),
              ),
            )
          : SingleChildScrollView(
              child: Text(
                _preview.isEmpty ? '（文件开头没有可预览的文字）' : _preview,
                style: const TextStyle(fontSize: 13, height: 1.6, color: Color(0xFF302C26)),
              ),
            ),
    );
  }

  Widget _chapterRule() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('章节规则',
            style: TextStyle(fontSize: 15, color: Color(0xFF20242B))),
        const SizedBox(height: 4),
        RadioGroup<_ChapterMode>(
          groupValue: _chapterMode,
          onChanged: (value) {
            if (value != null) setState(() => _chapterMode = value);
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final mode in _ChapterMode.values)
                RadioListTile<_ChapterMode>(
                  value: mode,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(mode.label, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(mode.hint,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF596270))),
                ),
            ],
          ),
        ),
        if (_chapterMode == _ChapterMode.custom)
          TextField(
            controller: _pattern,
            decoration: InputDecoration(
              hintText: r'例如：^第[0-9一二三四五六七八九十]+章',
              errorText: _patternError,
              isDense: true,
            ),
            onChanged: (_) {
              if (_patternError != null) setState(() => _patternError = null);
            },
          ),
      ],
    );
  }
}

enum _ChapterMode {
  auto('自动识别', '按「第一章 / 第十二回 / Chapter 1」等标题行分章'),
  sections('按长度分段', '不识别标题，按固定长度分成「第 N 节」'),
  custom('自定义正则', '用自定义正则匹配章节标题行');

  const _ChapterMode(this.label, this.hint);
  final String label;
  final String hint;
}

/// 兜底字符集名（与引擎层的默认值保持一致）。
const String kFallbackCharsetName = 'GB18030';
