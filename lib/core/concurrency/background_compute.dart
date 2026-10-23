import 'dart:async';
import 'dart:isolate';

/// 小列表直接计算；批量工作共用常驻 isolate，避免每次搜索都重新启动进程。
/// 入口必须是顶层/静态函数，参数只传快照，不能捕获 Ref、数据库或原生句柄。
const backgroundListThreshold = 256;
final _shared = BackgroundExecutor('library-compute');

Future<R> backgroundCompute<Q, R>(
  FutureOr<R> Function(Q) action,
  Q argument, {
  bool enabled = true,
}) async => enabled ? _shared.run(action, argument) : action(argument);

/// 顺序处理同一任务的命令。文件任务可单独持有实例，并在关闭时等待已接受工作。
class BackgroundExecutor {
  BackgroundExecutor(this.name);
  final String name;
  final _responses = ReceivePort();
  final _ready = Completer<SendPort>();
  final _exited = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  Future<SendPort>? _opening;
  var _next = 0;
  var _closing = false;

  Future<SendPort> _open() async {
    _responses.listen((dynamic message) {
      if (message is SendPort) {
        _ready.complete(message);
      } else if (message case (
        int id,
        Object? value,
        Object? error,
        StackTrace? stack,
      )) {
        final request = _pending.remove(id);
        if (error == null) {
          request?.complete(value);
        } else {
          request?.completeError(error, stack);
        }
      } else {
        final error = StateError('$name 后台计算已退出：$message');
        if (!_ready.isCompleted) _ready.completeError(error);
        for (final request in _pending.values) {
          request.completeError(error);
        }
        _pending.clear();
        _closing = true;
        if (!_exited.isCompleted) _exited.complete();
        _responses.close();
      }
    });
    try {
      await Isolate.spawn(
        _run,
        _responses.sendPort,
        onError: _responses.sendPort,
        onExit: _responses.sendPort,
        debugName: name,
      );
    } catch (error, stack) {
      _closing = true;
      _responses.close();
      _exited.complete();
      _ready.completeError(error, stack);
    }
    return _ready.future;
  }

  Future<R> run<Q, R>(FutureOr<R> Function(Q) action, Q argument) async {
    if (_closing) throw StateError('$name 已关闭');
    final commands = await (_opening ??= _open());
    final id = ++_next;
    final result = Completer<Object?>();
    _pending[id] = result;
    try {
      commands.send((id, action, argument));
    } catch (error, stack) {
      _pending.remove(id);
      result.completeError(error, stack);
    }
    return await result.future as R;
  }

  Future<void> close() async {
    if (_closing) return _exited.future;
    _closing = true;
    if (_opening == null) {
      _responses.close();
      _exited.complete();
    } else {
      (await _opening!).send(null);
    }
    await _exited.future;
  }
}

Future<void> _run(SendPort reply) async {
  final commands = ReceivePort();
  reply.send(commands.sendPort);
  await for (final message in commands) {
    if (message == null) break;
    final (id, action, argument) = message as (int, Function, Object?);
    try {
      final result = await Function.apply(action, [argument]);
      reply.send((id, result, null, null));
    } catch (error, stack) {
      reply.send((id, null, error, stack));
    }
  }
  commands.close();
}
