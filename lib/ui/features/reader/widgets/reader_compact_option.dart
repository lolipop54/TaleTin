import 'package:flutter/material.dart';

import 'listening_option_header.dart';
import 'reader_sheet.dart';

/// 短二级面板按内容占高；小屏或大字号超出可用高度时才滚动。
class ReaderCompactOption extends StatelessWidget {
  const ReaderCompactOption({
    super.key,
    required this.title,
    required this.child,
  });
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: ReaderSheet.backgroundOf(context),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: kToolbarHeight + 1,
          child: ListeningOptionHeader(title: Text(title)),
        ),
        Flexible(child: SingleChildScrollView(child: child)),
      ],
    ),
  );
}
