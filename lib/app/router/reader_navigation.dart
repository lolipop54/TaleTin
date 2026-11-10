import 'dart:async';

import 'package:go_router/go_router.dart';

/// 打开阅读页：叠在当前页之上，保留书架作为返回页。
///
/// 阅读页是 push 出来的 imperative 路由，不会反映在 routeInformationProvider
/// 的 uri 上（那里仍是书架），所以判断“是否已经在阅读页”必须看路由匹配列表。
/// 已经在目标书的阅读页时不再重复叠加，否则同一个通知连点几次就要按几次返回；
/// 已经在别的书的阅读页时只替换栈顶，不叠放两个阅读器。
void openReaderPage(GoRouter router, String location) {
  final matches = router.routerDelegate.currentConfiguration.matches;
  final top = matches.isEmpty ? null : matches.last.matchedLocation;
  if (top == location) return;
  if (top != null && top.startsWith('/reader/')) {
    unawaited(router.pushReplacement<void>(location));
  } else {
    unawaited(router.push<void>(location));
  }
}
