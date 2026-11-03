import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 一条 Vlog 成片记录
class VlogRecord {
  final String videoPath;
  final String title;
  final String day; // 关联的日期
  final int createdAt; // 毫秒时间戳

  const VlogRecord({
    required this.videoPath,
    required this.title,
    required this.day,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'video_path': videoPath,
        'title': title,
        'day': day,
        'created_at': createdAt,
      };

  factory VlogRecord.fromJson(Map<String, dynamic> j) => VlogRecord(
        videoPath: (j['video_path'] as String?) ?? '',
        title: (j['title'] as String?) ?? '我的 Vlog',
        day: (j['day'] as String?) ?? '',
        createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
      );
}

/// Vlog 成片记录存储（本地 SharedPreferences，存一个 JSON 数组）。
///
/// add/remove 完成后会向 [changes] 流发出最新列表，订阅者（如 VlogLibraryPage）
/// 据此自动刷新，不再需要用户手动点刷新或页面间互相调用 _load()。
class VlogStore {
  static const _kKey = 'vlog_records';

  final _controller = StreamController<List<VlogRecord>>.broadcast();

  /// 记录变更流：add/remove 完成后发出最新列表（按 createdAt 倒序）。
  Stream<List<VlogRecord>> get changes => _controller.stream;

  void dispose() => _controller.close();

  Future<List<VlogRecord>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      final records = list
          .map((e) => VlogRecord.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      // 按创建时间倒序
      records.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return records;
    } catch (_) {
      return [];
    }
  }

  Future<void> add(VlogRecord record) async {
    final all = await loadAll();
    all.insert(0, record);
    await _save(all);
    _controller.add(await loadAll());
  }

  Future<void> remove(String videoPath) async {
    final all = await loadAll();
    all.removeWhere((r) => r.videoPath == videoPath);
    await _save(all);
    _controller.add(await loadAll());
  }

  Future<void> _save(List<VlogRecord> records) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKey, jsonEncode(records.map((r) => r.toJson()).toList()));
  }
}

final vlogStore = VlogStore();
