part of 'file_layout_checkpoint_store.dart';

// 每本书保存最近的版式。连续单页章按 32 循环，只保存每段的起止章号和首章位置。
const _spreadRunName = 'spread-runs.json';

Future<Map<int, int>> _readSpreadRuns(String path, String key) => Isolate.run(
  () {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > 512 * 1024) {
        return <int, int>{};
      }
      final data = jsonDecode(file.readAsStringSync()) as List;
      if (data.first != key) return <int, int>{};
      final runs = <int, int>{};
      for (final row in (data[1] as List).cast<List>()) {
        final start = row[0] as int, end = row[1] as int, slot = row[2] as int;
        if (start < 0 ||
            end < start ||
            end - start > 100000 ||
            slot < 0 ||
            slot > 32) {
          return <int, int>{};
        }
        for (var i = start; i <= end; i++) {
          runs[i] = slot == 0 ? 0 : (slot - 1 + i - start) % 32 + 1;
        }
      }
      return runs;
    } on Object {
      return <int, int>{};
    }
  },
);

Future<void> _writeSpreadRuns(String path, String key, Map<int, int> runs) =>
    Isolate.run(() {
      final rows = <List<int>>[];
      for (final index in runs.keys.toList()..sort()) {
        final slot = runs[index]!;
        final last = rows.lastOrNull;
        if (last != null &&
            index == last[1] + 1 &&
            index - last[0] <= 100000 &&
            slot ==
                (last[2] == 0 ? 0 : (last[2] - 1 + index - last[0]) % 32 + 1)) {
          last[1] = index;
        } else {
          rows.add([index, index, slot]);
        }
      }
      final data = jsonEncode([key, rows]);
      if (data.length > 512 * 1024) return;
      final file = File(path);
      file.parent.createSync(recursive: true);
      final tmp = File('$path.tmp');
      tmp.writeAsStringSync(data, flush: true);
      tmp.renameSync(path);
    });
