import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/di/app_providers.dart';
import '../../../../domain/models/tts_state.dart';

/// 先订阅再发同步快照，避免首帧与订阅之间漏掉 started。
final listeningViewStateProvider = StreamProvider<ListeningState>((ref) {
  final service = ref.watch(listeningServiceProvider);
  return Stream<ListeningState>.multi((sink) {
    final subscription = service.state.listen(
      sink.add,
      onError: sink.addError,
      onDone: sink.close,
    );
    sink.add(service.snapshot);
    sink.onCancel = subscription.cancel;
  });
});
