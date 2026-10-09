import 'package:flutter/material.dart';

Future<void> saveSetting(BuildContext context, Future<void> Function() save) async {
  try { await save(); }
  catch (_) { if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设置未保存，请重试')));
  } }
}
