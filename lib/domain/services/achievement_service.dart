import 'dart:async';
import '../repositories/achievement_repository.dart';
import '../rules/achievement_rules.dart';

/// 应用级评估，始终监听真实写入，不依赖是否打开成就页。
class AchievementService {
  AchievementService(this.repository);
  final AchievementRepository repository;
  final _events=StreamController<AchievementEvaluation>.broadcast();
  StreamSubscription<void>? _subscription;
  Future<void> _pending=Future.value();
  Future<void>? _initialization;
  AchievementEvaluation? snapshot;
  bool _disposed=false;

  Future<void> initialize() => _initialization ??= _initialize().catchError((Object e,StackTrace s) {
    _initialization=null;
    Error.throwWithStackTrace(e,s);
  });
  Future<void> _initialize() async {
    // 启动/恢复只补正确记录，历史条件和上次未展示奖励均不重播。
    snapshot=await repository.evaluate(silently:true);
    if(_disposed) return;
    _subscription=repository.changes.listen((_) { unawaited(refresh()); });
  }
  Future<void> refresh() {
    if (_disposed) return _pending;
    _pending=_pending.then((_) async {
      final next=await repository.evaluate();
      if(!_disposed) { snapshot=next; _events.add(next); }
    }).catchError((Object e,StackTrace s) { if(!_disposed) _events.addError(e,s); });
    return _pending;
  }
  Stream<AchievementEvaluation> watch() => Stream.multi((out) {
    // 先订阅再发布快照，避免读取间隔漏掉最新更新。
    final sub=_events.stream.listen(out.add,onError:out.addError);
    if(snapshot case final value?) out.add(value);
    out.onCancel=sub.cancel;
  });
  Future<bool> claim(String id) async {
    if (_disposed) return false;
    final result=await repository.claim(id);
    await refresh();
    return result;
  }
  Future<void>? _closing;
  Future<void> shutdown() => _closing ??= _shutdown();
  Future<void> _shutdown() async {
    _disposed=true;
    await _initialization;
    await _subscription?.cancel();
    await _pending;
    await _events.close();
  }
  void dispose() { unawaited(shutdown()); }
}
