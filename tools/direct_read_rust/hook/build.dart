// Copyright (c) 2026 GT Reader contributors. MIT license, see LICENSE.
import 'dart:io';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// Cargo compiles Rust. Flutter supplies the target NDK compiler via Code Assets.
Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final (target, library) = switch ((
      code.targetOS,
      code.targetArchitecture,
    )) {
      (OS.android, Architecture.arm64) => (
        'aarch64-linux-android',
        'libgt_reader_native.so',
      ),
      (OS.android, Architecture.arm) => (
        'armv7-linux-androideabi',
        'libgt_reader_native.so',
      ),
      (OS.android, Architecture.x64) => (
        'x86_64-linux-android',
        'libgt_reader_native.so',
      ),
      (OS.windows, Architecture.x64) => (
        'x86_64-pc-windows-msvc',
        'gt_reader_native.dll',
      ),
      _ => throw UnsupportedError(
        'Rust 库未配置目标 ${code.targetOS}/${code.targetArchitecture}',
      ),
    };
    final cargoRoot = input.outputDirectory.resolve('cargo/');
    final environment = <String, String>{
      'CARGO_TARGET_DIR': cargoRoot.toFilePath(),
    };
    if (code.targetOS == OS.android) {
      final compiler = code.cCompiler?.compiler;
      if (compiler == null) throw StateError('Flutter 没有提供 Android NDK 编译器');
      final prefix = code.targetArchitecture == Architecture.arm
          ? 'armv7a-linux-androideabi'
          : target;
      final linker = compiler.resolve(
        '$prefix${code.android.targetNdkApi}-clang${Platform.isWindows ? '.cmd' : ''}',
      );
      environment['CARGO_TARGET_${target.toUpperCase().replaceAll('-', '_')}_LINKER'] =
          linker.toFilePath();
      environment['CARGO_ENCODED_RUSTFLAGS'] =
          '-Clink-arg=-Wl,-z,max-page-size=16384';
    }
    final cargo = await Process.run('cargo', [
      'build',
      '--release',
      '--locked',
      '--offline',
      '--target',
      target,
      '--manifest-path',
      input.packageRoot.resolve('Cargo.toml').toFilePath(),
    ], environment: environment);
    if (cargo.exitCode != 0) throw StateError('Rust 构建失败：${cargo.stderr}');
    final bundled = input.outputDirectory.resolve(library);
    await File.fromUri(
      cargoRoot.resolve('$target/release/$library'),
    ).copy(bundled.toFilePath());
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'reader_native',
        file: bundled,
        linkMode: DynamicLoadingBundled(),
      ),
    );
    output.dependencies.addAll([
      input.packageRoot.resolve('Cargo.toml'),
      input.packageRoot.resolve('Cargo.lock'),
      ...Directory.fromUri(
        input.packageRoot.resolve('src/'),
      ).listSync().whereType<File>().map((f) => f.uri),
    ]);
  });
}
