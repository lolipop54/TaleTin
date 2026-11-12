import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

const offlineDictionaryIncluded = bool.fromEnvironment(
  'GT_INCLUDE_OFFLINE_DICTIONARY',
  defaultValue: true,
);
const traceDictionaryLookup = bool.fromEnvironment('GT_TRACE_DICTIONARY');
const _channel = MethodChannel('gtreader/offline_dictionary');

class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.language,
    required this.partOfSpeech,
    required this.sounds,
    required this.glosses,
    this.sourceWord,
    this.sourceId = 'wiktionary',
  });

  factory DictionaryEntry._decode(String value) {
    final data = jsonDecode(value) as Map<String, Object?>;
    return DictionaryEntry(
      word: data['word']! as String,
      language: data['language']! as String,
      partOfSpeech: data['pos']! as String,
      sounds: (data['sounds']! as List<Object?>).cast<String>(),
      glosses: (data['glosses']! as List<Object?>).cast<String>(),
      sourceWord: data['source_word'] as String?,
      sourceId: data['source'] as String? ?? 'wiktionary',
    );
  }

  final String word;
  final String language;
  final String partOfSpeech;
  final List<String> sounds;
  final List<String> glosses;
  final String? sourceWord;
  final String sourceId;

  String get sourceLabel => switch (sourceId) {
    'cow' || 'cow_synonyms' => '汉语开放词网 · 来源',
    'cow_linked' => '汉语开放词网 · 译文来源',
    'cedict' => 'CC-CEDICT · 译文来源',
    'ecdict' => 'ECDICT · 来源',
    _ => '维基词典 · 来源',
  };

  Uri get source => switch (sourceId) {
    'cow' ||
    'cow_synonyms' ||
    'cow_linked' => Uri.https('bond-lab.github.io', '/cow/'),
    'cedict' => Uri.https('www.mdbg.net', '/chinese/dictionary', {
      'page': 'worddict',
      'wdrst': '0',
      'wdqb': word,
    }),
    'ecdict' => Uri.https('github.com', '/skywind3000/ECDICT'),
    _ => Uri.https('zh.wiktionary.org', '/wiki/${sourceWord ?? word}'),
  };
}

typedef DictionaryLookup = Future<List<DictionaryEntry>> Function(String term);

final offlineDictionaryProvider = Provider<DictionaryLookup>((ref) => _lookup);

Future<List<DictionaryEntry>> _lookup(String term) async {
  final records = await _channel.invokeListMethod<String>('lookup', {
    'term': term,
    if (traceDictionaryLookup) 'trace': true,
  });
  return [
    for (final record in records ?? const <String>[])
      DictionaryEntry._decode(record),
  ];
}
