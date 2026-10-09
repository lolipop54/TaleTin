import 'package:flutter/material.dart';

import '../view_models/reader_view_model.dart';

/// 所有收起入口共用保存流程；保存失败时保留当前选择和面板。
class ReaderOptionController extends ChangeNotifier {
  ReaderOptionController(this.finish);
  final Future<void> Function(ReaderPanel?) finish;
  Future<bool> Function()? save;
  bool busy = false, canPop = false;

  Future<void> close([ReaderPanel? next]) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      if (await save?.call() == false) return;
      await finish(next);
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void allowPop() {
    canPop = true;
    notifyListeners();
  }
}

class ReaderOptionScope extends InheritedWidget {
  const ReaderOptionScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final ReaderOptionController controller;
  static ReaderOptionController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ReaderOptionScope>()
      ?.controller;
  @override
  bool updateShouldNotify(ReaderOptionScope oldWidget) =>
      controller != oldWidget.controller;
}

/// 子面板登记自己的保存方法；单独打开时同样支持返回键自动保存。
class ReaderOptionAutosave extends StatefulWidget {
  const ReaderOptionAutosave({
    super.key,
    required this.save,
    required this.child,
  });
  final Future<bool> Function() save;
  final Widget child;
  @override
  State<ReaderOptionAutosave> createState() => _AutosaveState();
}

class _AutosaveState extends State<ReaderOptionAutosave> {
  ReaderOptionController? _controller;
  bool _ownsController = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null) return;
    _controller = ReaderOptionScope.maybeOf(context);
    _ownsController = _controller == null;
    _controller ??= ReaderOptionController((_) async {
      _controller!.allowPop();
      Navigator.of(context).pop();
    });
    _controller!.save = widget.save;
  }

  @override
  void didUpdateWidget(ReaderOptionAutosave oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller!.save = widget.save;
  }

  @override
  void dispose() {
    _controller!.save = null;
    if (_ownsController) _controller!.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ReaderOptionScope(
    controller: _controller!,
    child: ListenableBuilder(
      listenable: _controller!,
      builder: (context, _) => PopScope(
        canPop: !_ownsController || _controller!.canPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _ownsController) _controller!.close();
        },
        child: widget.child,
      ),
    ),
  );
}
