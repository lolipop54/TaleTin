/// 导入相关的失败类型与文案。
///
/// 错误码是稳定值（写入 `import_jobs.errorCode`、用于重试判断），
/// 面向用户的说明由 [ImportFailure.message] 统一给出，避免各处拼文案。
library;

/// 导入失败原因。
enum ImportErrorCode {
  /// 扩展名与真实内容都不是支持的格式，或格式包含不支持的加密／版式。
  unsupportedFormat('unsupportedFormat'),
  emptyFile('emptyFile'),
  tooLarge('tooLarge'),
  noSpace('noSpace'),

  /// 与书架已有书籍哈希相同
  duplicate('duplicate'),

  /// 容器损坏、缺少必要文件、结构不合法
  invalidContainer('invalidContainer'),

  /// ZIP 条目越界（路径穿越）或超出防护阈值
  unsafeArchive('unsafeArchive'),

  /// 编码无法识别或解码失败（TXT）
  decodeFailed('decodeFailed'),

  /// 解析成功但正文为空
  emptyContent('emptyContent'),
  cancelled('cancelled'),
  unknown('unknown');

  const ImportErrorCode(this.code);
  final String code;

  static ImportErrorCode fromCode(String? code) => values.firstWhere(
        (e) => e.code == code,
        orElse: () => ImportErrorCode.unknown,
      );

  /// 是否为「重试可能成功」的临时失败。
  /// 格式不支持、超限、损坏属于确定性失败，重试没有意义。
  bool get isRetryable => switch (this) {
        ImportErrorCode.noSpace ||
        ImportErrorCode.unknown ||
        ImportErrorCode.cancelled =>
          true,
        _ => false,
      };
}

/// 一次导入失败：错误码 + 用户可读说明（可附补充信息）。
class ImportFailure implements Exception {
  const ImportFailure(this.code, [this.detail]);

  final ImportErrorCode code;

  /// 补充信息，例如「单条资源 62 MB 超出 50 MB 上限」
  final String? detail;

  /// 界面上显示的短说明
  String get message => switch (code) {
        ImportErrorCode.unsupportedFormat => '不支持的格式',
        ImportErrorCode.emptyFile => '文件为空',
        ImportErrorCode.tooLarge => '文件过大',
        ImportErrorCode.noSpace => '存储空间不足',
        ImportErrorCode.duplicate => '书架中已有相同文件',
        ImportErrorCode.invalidContainer => '文件损坏或结构不完整',
        ImportErrorCode.unsafeArchive => '文件内容不安全，已拒绝',
        ImportErrorCode.decodeFailed => '文字编码无法识别',
        ImportErrorCode.emptyContent => '没有解析到正文',
        ImportErrorCode.cancelled => '已取消',
        ImportErrorCode.unknown => '导入失败',
      };

  /// 失败原因 + 细节，导入队列按「导入失败 · 原因」展示
  String get displayText =>
      detail == null ? message : '$message · $detail';

  @override
  String toString() => 'ImportFailure(${code.code}${detail == null ? '' : ': $detail'})';
}
