import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../../domain/models/book_document.dart';
import '../../domain/models/locator.dart';
import '../../domain/models/note_draft.dart';
import '../../domain/models/source_position_preparation.dart';
import '../database/app_database.dart';
import '../repositories/drift_annotation_repository.dart';

const sourcePositionProofKey = 'sourcePositionProof';

Future<SourcePositionProof?> readSourcePositionProof(
  AppDatabase db,
  String root,
  String id,
) async {
  final saved =
      await (db.select(db.preferences)..where(
            (t) =>
                t.scope.equals('book') &
                t.scopeId.equals(id) &
                t.key.equals(sourcePositionProofKey),
          ))
          .getSingleOrNull();
  if (saved != null) {
    return SourcePositionProof.fromJson(jsonDecode(saved.valueJson));
  }
  // 兼容现有可信来源索引。无来源摘要的旧全文 JSON 不能补造可信证明。
  final directory = p.join(root, id, 'content', '$kContentVersion');
  final file = File(p.join(directory, 'manifest.json'));
  if (!file.existsSync()) return null;
  final manifest = jsonDecode(file.readAsStringSync()) as Map;
  final index = manifest['sourceIndex'] as Map?;
  if (index == null || manifest['contentVersion'] != kContentVersion) {
    return null;
  }
  final format = index['format'] as String;
  var options = <String, dynamic>{};
  if (format == 'txt') {
    final file = File(p.join(directory, 'txt.options'));
    if (!file.existsSync()) return null;
    options = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  }
  return SourcePositionProof(
    index['sourceDigest'] as String,
    manifest['positionRules'] as String? ??
        sourcePositionRules(
          format,
          charset: index['charset'] as String?,
          chapterPattern: options['chapterPattern'] as String?,
          forceSections: options['forceSectionFallback'] == true,
          txtRevision: manifest['txtHeadingRevision'] as int? ?? 0,
        ),
    index['sourceStamp'] as String? ?? '',
  );
}

/// 删除缓存前留下可信证据；记录不含正文，不受正文缓存清理影响。
Future<void> preserveSourcePositionProof(
  AppDatabase db,
  String root,
  String id,
) async {
  final proof = await readSourcePositionProof(db, root, id);
  if (proof == null) return;
  await db
      .into(db.preferences)
      .insertOnConflictUpdate(
        PreferencesCompanion.insert(
          scope: 'book',
          scopeId: id,
          key: sourcePositionProofKey,
          valueJson: jsonEncode(proof.toJson()),
          updatedAt: DateTime.now().toUtc(),
        ),
      );
}

Future<SourcePositionPreparation> loadSourcePositionPreparation(
  AppDatabase db,
  String root,
  String id,
) async {
  final notes = await DriftAnnotationRepository(db).loadForRelocation(id);
  final positions = await (db.select(
    db.readingPositions,
  )..where((t) => t.bookId.equals(id))).get();
  final draftRow =
      await (db.select(db.preferences)..where(
            (t) =>
                t.scope.equals('book') &
                t.scopeId.equals(id) &
                t.key.equals('noteDraft'),
          ))
          .getSingleOrNull();
  final draft = draftRow == null
      ? null
      : NoteDraft.fromJson(jsonDecode(draftRow.valueJson));
  final proof = await readSourcePositionProof(db, root, id);
  final anchors = [
    for (final note in notes) ...[note.start, if (note.end != null) note.end!],
    for (final row in positions) Locator.fromJson(jsonDecode(row.locatorJson)),
    if (draft != null) ...[draft.range.start, draft.range.end],
  ];
  return SourcePositionPreparation(
    proof: proof,
    anchors: anchors,
    txtHints: await _oldTxtHints(root, id, proof, anchors),
  );
}

Future<TxtSourcePositionHints?> _oldTxtHints(
  String root,
  String id,
  SourcePositionProof? proof,
  List<Locator> anchors,
) async {
  if (proof == null || !anchors.any((anchor) => !anchor.needsRelocation)) {
    return null;
  }
  final manifest = File(
    p.join(root, id, 'content', '$kContentVersion', 'manifest.json'),
  );
  if (!await manifest.exists()) return null;
  final data = jsonDecode(await manifest.readAsString()) as Map;
  final index = data['sourceIndex'] as Map?;
  if (index == null ||
      index['format'] != 'txt' ||
      index['sourceDigest'] != proof.digest ||
      index['charset'] is! String ||
      index['chapters'] is! Map) {
    return null;
  }
  final ranges = index['chapters'] as Map;
  final positions = [
    for (final anchor in anchors)
      if (!anchor.needsRelocation && anchor.contentVersion == kContentVersion)
        if (ranges[anchor.chapterId] case [final int start, final int end])
          (anchor: anchor, start: start, end: end),
  ];
  return positions.isEmpty
      ? null
      : TxtSourcePositionHints(
          proof.digest,
          index['charset'] as String,
          positions,
        );
}
