part of 'original_host_controller.dart';

/// 首次显示所需参数先在 Dart 备齐，再在同一网页任务内配置和启动分栏。
/// 不给浏览器留下按中间字号/信息栏状态先排一次整章的机会。
extension OriginalHostStartup on OriginalHostController {
  void beginStartup() => _startupCommands ??= [];

  void cancelStartup() => _startupCommands = null;

  bool _queueStartup(String script) {
    final commands = _startupCommands;
    if (commands == null) return false;
    const prefixes = [
      '__gt.configure(',
      '__gt.information(',
      '__gt.applyStyle(',
      '__gt.setContentTitles(',
      '__gt.setContentMap(',
      '__gt.clearHighlights(',
      '__gt.setHighlights(',
    ];
    if (!prefixes.any(script.startsWith)) return false;
    // 高亮数据必须先备齐，但几何绘制由首次真实分栏完成后的原流程执行。
    commands.add(
      script.replaceFirst('__gt.setHighlights(', '__gt.setStartupHighlights('),
    );
    return true;
  }

  String finishStartupScript(String start) {
    final commands = _startupCommands;
    _startupCommands = null;
    if (commands == null) return start;
    return '(function(){if(!window.__gt)return false;'
        '${commands.map(_diagnosticCommand).join(';')};$start;return true;})()';
  }
}
