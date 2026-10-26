/// [ReadingSettingsRepository] 的 drift 实现（设计文档 7.1 preferences 表）。
///
/// 一个键一行：全局与单书覆盖都写 `preferences`，靠 `scope/scopeId` 区分。
/// 值统一存 JSON 文本，解码时单项越界只回退该项（`ReadingSettings.fromJson`）。
library;

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/models/reading_settings.dart';
import '../../domain/repositories/reading_settings_repository.dart';
import '../database/app_database.dart';

class DriftReadingSettingsRepository implements ReadingSettingsRepository {
  DriftReadingSettingsRepository(this._db);

  final AppDatabase _db;

  /// 全局阅读默认值的键
  static const _typographyKey = 'typography';
  static const _fontOrderKey = 'fontOrder';

  /// 阅读主题的键
  static const _themeKey = 'readingTheme';

  /// 窗口亮度覆盖的键（一本书一行；没有这行表示跟随系统）
  static const _brightnessKey = 'brightness';

  /// 状态信息显示开关的键（全局；没有这行表示显示）
  static const _statusInfoKey = 'statusInfo';

  /// 全局范围的固定 scopeId（scopes 表的 scope=global 行）
  static const _globalScopeId = 'global';

  @override
  Future<ReadingSettings?> loadGlobal() async {
    final json = await _readJson(
      scope: _globalScope,
      scopeId: _globalScopeId,
      key: _typographyKey,
    );
    return json == null ? null : ReadingSettings.fromJson(json);
  }

  @override
  Future<void> saveGlobal(ReadingSettings settings) => _writeJson(
    scope: _globalScope,
    scopeId: _globalScopeId,
    key: _typographyKey,
    json: settings.toJson(),
  );

  @override
  Future<void> resetFontFamily(String family) => _db.transaction(() async {
    final rows =
        await (_db.select(_db.preferences)..where(
              (t) =>
                  t.key.equals(_typographyKey) &
                  t.scope.isIn([_globalScope, _bookScope]),
            ))
            .get();
    for (final row in rows) {
      final Map<String, dynamic> json;
      try {
        final value = jsonDecode(row.valueJson);
        if (value is! Map<String, dynamic>) continue;
        json = value;
      } on FormatException {
        // 沿用读取设置的规则：坏记录当作未设置，不阻止清理其他字体引用。
        continue;
      }
      if (json['fontFamily'] != family) continue;
      json['fontFamily'] = 'sans-serif';
      await _writeJson(
        scope: row.scope,
        scopeId: row.scopeId,
        key: row.key,
        json: json,
      );
    }
    final order = await loadFontOrder();
    if (order.contains(family)) {
      await saveFontOrder(order.where((id) => id != family).toList());
    }
  });

  @override
  Future<List<String>> loadFontOrder() async {
    final json = await _readJson(
      scope: _globalScope,
      scopeId: _globalScopeId,
      key: _fontOrderKey,
    );
    return (json?['families'] as List?)?.whereType<String>().toList() ?? [];
  }

  @override
  Future<void> saveFontOrder(List<String> families) => _writeJson(
    scope: _globalScope,
    scopeId: _globalScopeId,
    key: _fontOrderKey,
    json: {
      'families': families
          .where((id) => id != '__original' && id != 'sans-serif')
          .toSet()
          .toList(),
    },
  );

  @override
  Future<ReadingSettingsOverrides?> loadOverrides(String bookId) async {
    final json = await _readJson(
      scope: _bookScope,
      scopeId: bookId,
      key: _typographyKey,
    );
    if (json == null) return null;
    final overrides = ReadingSettingsOverrides.fromJson(json);
    // 每项都为空时当作没有覆盖，避免「恢复全局」后留下空壳行
    return overrides.isEmpty ? null : overrides;
  }

  @override
  Future<void> saveOverrides(
    String bookId,
    ReadingSettingsOverrides overrides,
  ) async {
    if (overrides.isEmpty) {
      await clearOverrides(bookId);
      return;
    }
    await _writeJson(
      scope: _bookScope,
      scopeId: bookId,
      key: _typographyKey,
      json: overrides.toJson(),
    );
  }

  @override
  Future<void> clearOverrides(String bookId) async {
    await (_db.delete(_db.preferences)..where(
          (t) =>
              t.scope.equals(_bookScope) &
              t.scopeId.equals(bookId) &
              t.key.isIn([
                _typographyKey,
                _themeKey,
                _brightnessKey,
                'readingBackground',
              ]),
        ))
        .go();
  }

  @override
  Future<String?> loadThemeId({String? bookId}) => _readTheme(
    scope: bookId == null ? _globalScope : _bookScope,
    scopeId: bookId ?? _globalScopeId,
  );

  @override
  Future<void> saveThemeId(String? themeId, {String? bookId}) async {
    final scope = bookId == null ? _globalScope : _bookScope;
    final scopeId = bookId ?? _globalScopeId;
    if (themeId == null) {
      await (_db.delete(_db.preferences)..where(
            (t) =>
                t.scope.equals(scope) &
                t.scopeId.equals(scopeId) &
                t.key.equals(_themeKey),
          ))
          .go();
      return;
    }
    await _writeJson(
      scope: scope,
      scopeId: scopeId,
      key: _themeKey,
      json: {'id': themeId},
    );
  }

  @override
  Future<double?> loadBrightness(String bookId) async {
    final json = await _readJson(
      scope: _bookScope,
      scopeId: bookId,
      key: _brightnessKey,
    );
    final value = json?['value'];
    return value is num ? value.toDouble().clamp(0.0, 1.0) : null;
  }

  @override
  Future<double?> loadCustomBrightness(String bookId) async {
    final json = await _readJson(
      scope: _bookScope,
      scopeId: bookId,
      key: _brightnessKey,
    );
    final value = json?['custom'] ?? json?['value'];
    return value is num ? value.toDouble().clamp(0.0, 1.0) : null;
  }

  @override
  Future<void> saveBrightness(String bookId, double? value) async {
    final custom = value?.clamp(0.0, 1.0) ?? await loadCustomBrightness(bookId);
    await _writeJson(
      scope: _bookScope,
      scopeId: bookId,
      key: _brightnessKey,
      json: {'value': value?.clamp(0.0, 1.0), 'custom': custom},
    );
  }

  @override
  Future<bool> loadStatusInfoVisible() async {
    final json = await _readJson(
      scope: _globalScope,
      scopeId: _globalScopeId,
      key: _statusInfoKey,
    );
    final value = json?['visible'];
    return value is bool ? value : true;
  }

  @override
  Future<void> saveStatusInfoVisible(bool visible) => _writeJson(
    scope: _globalScope,
    scopeId: _globalScopeId,
    key: _statusInfoKey,
    json: {'visible': visible},
  );

  Future<String?> _readTheme({
    required String scope,
    required String scopeId,
  }) async {
    final json = await _readJson(
      scope: scope,
      scopeId: scopeId,
      key: _themeKey,
    );
    final id = json?['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  static const _globalScope = 'global';
  static const _bookScope = 'book';

  /// 读一行并解析 JSON；行不存在、JSON 坏了都返回 null（当作没设置过）
  Future<Map<String, Object?>?> _readJson({
    required String scope,
    required String scopeId,
    required String key,
  }) async {
    final row =
        await (_db.select(_db.preferences)..where(
              (t) =>
                  t.scope.equals(scope) &
                  t.scopeId.equals(scopeId) &
                  t.key.equals(key),
            ))
            .getSingleOrNull();
    if (row == null) return null;
    try {
      final decoded = jsonDecode(row.valueJson);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _writeJson({
    required String scope,
    required String scopeId,
    required String key,
    required Map<String, Object?> json,
  }) async {
    await _db
        .into(_db.preferences)
        .insertOnConflictUpdate(
          PreferencesCompanion.insert(
            scope: scope,
            scopeId: scopeId,
            key: key,
            valueJson: jsonEncode(json),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }
}
