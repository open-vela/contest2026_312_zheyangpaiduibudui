import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ai_vlog/services/vlog_store.dart';

/// ① 跨页状态同步的行为规格。
///
/// VlogStore 必须在 add/remove 完成后向 [changes] 流发出最新列表，
/// 这样 VlogLibraryPage 订阅后能在下载/导入/删除后自动刷新，
/// 而不必依赖用户手动点刷新按钮。
///
/// 待跑：flutter test test/vlog_store_test.dart
/// （环境无 Flutter SDK，RED/GREEN 留装环境后执行。）
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // RED 条件：若 VlogStore.add 末尾未 _controller.add(...)，此测试必红。
  test('add 后 changes 流发出含新记录的列表', () async {
    final completer = Completer<List<VlogRecord>>();
    final sub = vlogStore.changes.listen((list) {
      if (!completer.isCompleted) completer.complete(list);
    });

    await vlogStore.add(VlogRecord(
      videoPath: '/tmp/a.mp4',
      title: 'A',
      day: '',
      createdAt: 1,
    ));

    final list = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(list.any((r) => r.videoPath == '/tmp/a.mp4'), isTrue);
  });

  // RED 条件：若 VlogStore.remove 末尾未 _controller.add(...)，此测试必红。
  test('remove 后 changes 流发出不含该记录的列表', () async {
    await vlogStore.add(VlogRecord(
      videoPath: '/tmp/b.mp4',
      title: 'B',
      day: '',
      createdAt: 2,
    ));

    final completer = Completer<List<VlogRecord>>();
    final sub = vlogStore.changes.listen((list) {
      if (!completer.isCompleted) completer.complete(list);
    });

    await vlogStore.remove('/tmp/b.mp4');

    final list = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(list.any((r) => r.videoPath == '/tmp/b.mp4'), isFalse);
  });

  // 行为规格：changes 发出的列表必须按 createdAt 倒序（最新在前），
  // 与 loadAll 的排序一致——库页订阅后直接展示，无需再排。
  test('changes 流发出按 createdAt 倒序的列表', () async {
    final completer = Completer<List<VlogRecord>>();
    final sub = vlogStore.changes.listen((list) {
      if (!completer.isCompleted) completer.complete(list);
    });

    await vlogStore.add(VlogRecord(
      videoPath: '/tmp/only.mp4',
      title: 'only',
      day: '',
      createdAt: 300,
    ));

    final list = await completer.future.timeout(const Duration(seconds: 1));
    await sub.cancel();

    expect(list, isNotEmpty);
    expect(list.first.videoPath, '/tmp/only.mp4');
  });
}
