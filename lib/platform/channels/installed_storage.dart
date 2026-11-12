import 'dart:io';

import 'package:flutter/services.dart';

import '../../domain/repositories/storage_repository.dart';

const _channel = MethodChannel('gtreader/installed_storage');

Future<InstalledStorage?> readInstalledStorage() async {
  if (!Platform.isAndroid) return null;
  final sizes = (await _channel.invokeMapMethod<String, int>('storageUsage'))!;
  return (
    packageBytes: sizes['packageBytes']!,
    bundledDictionaryBytes: sizes['bundledDictionaryBytes']!,
    extractedDictionaryBytes: sizes['extractedDictionaryBytes']!,
  );
}
