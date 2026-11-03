import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/device_client.dart';
import '../services/vlog_store.dart';
import '../utils/polling.dart';
import '../utils/retry.dart';

/// 设备页：输入视频源（电脑后端）的局域网地址，接收其生成的 Vlog。
///
/// 视频由电脑后端异步生成。App 按其 IP 走 HTTP：GET /list 拉列表，GET /download?name= 下载。
/// 接收方式：
/// - 自动接收（默认开）：连上后定时轮询 /list，发现本地没有的新视频自动下载入库。
/// - 手动下载：也可点列表里的下载按钮单独拉。
///
/// ② 下载重试+可取消：失败指数退避重试 3 次；下载中可点 ✕ 取消。
/// ③ 断线退避重连：轮询失败指数退避 10s→60s，连续 3 次失败提示用户检查连接。
class DevicePage extends StatefulWidget {
  const DevicePage({super.key, this.client});

  /// 测试注入：可传入 mock DeviceClient 验证重试/取消逻辑。
  /// 生产使用默认全局单例 deviceClient。
  final DeviceClient? client;

  @override
  State<DevicePage> createState() => _DevicePageState();
}

class _DevicePageState extends State<DevicePage> {
  static const _kLastIp = 'last_device_ip';
  static const _kAutoReceive = 'auto_receive';

  late final DeviceClient _client;

  final _ipCtrl = TextEditingController();
  bool _loading = false;
  List<RemoteVlog> _remote = [];
  String? _error;
  bool _connected = false;

  // 自动接收
  bool _autoReceive = true;
  Timer? _pollTimer;
  int _failCount = 0; // 连续轮询失败次数（③ 退避/提示）
  String? _pollWarning; // 连续失败 ≥ kWarnAfterFails 时的提示

  // 正在下载的项 -> 进度
  final Map<String, double?> _downloading = {};
  // 正在下载的项 -> CancelToken（② 取消）
  final Map<String, CancelToken> _cancels = {};
  // 已下载过的原始文件名，用于判断"新视频"
  Set<String> _localNames = {};

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? deviceClient;
    _restore();
    _loadLocalNames();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString(_kLastIp);
    final auto = prefs.getBool(_kAutoReceive) ?? true;
    if (!mounted) return;
    setState(() {
      if (last != null && last.isNotEmpty) _ipCtrl.text = last;
      _autoReceive = auto;
    });
  }

  Future<void> _loadLocalNames() async {
    final all = await vlogStore.loadAll();
    final names = <String>{};
    for (final r in all) {
      final base = r.videoPath.split(RegExp(r'[\\/]')).last;
      final m = RegExp(r'^dev_\d+_(.+)$').firstMatch(base);
      if (m != null) names.add(m.group(1)!);
      names.add(r.title);
    }
    if (mounted) setState(() => _localNames = names);
  }

  bool _isNew(RemoteVlog v) {
    final stem = v.name.replaceAll(RegExp(r'\.[^.]+$'), '');
    return !_localNames.contains(v.name) && !_localNames.contains(stem);
  }

  Future<void> _connect() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) {
      _snack('请输入视频源地址', ok: false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _client.fetchList(ip);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kLastIp, ip);
      if (!mounted) return;
      setState(() {
        _remote = list;
        _connected = true;
        _failCount = 0; // 连接成功重置退避
        _pollWarning = null;
      });
      _scheduleNextPoll();
      if (_autoReceive) _autoFetchNew();
      if (list.isEmpty) _snack('已连接，但暂无 Vlog', ok: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = DeviceClient.describeError(e);
        _connected = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// ③ 一次性 Timer + 递归调度，间隔由 nextPollDelay(_failCount) 决定：
  /// 成功回 10s，失败指数退避 20s/40s/60s 封顶。
  void _scheduleNextPoll() {
    _pollTimer?.cancel();
    if (!_autoReceive || !_connected) return;
    final delay = nextPollDelay(failCount: _failCount);
    _pollTimer = Timer(delay, _refreshAndAutoFetch);
  }

  Future<void> _refreshAndAutoFetch() async {
    if (!_connected) return;
    try {
      final list = await _client.fetchList(_ipCtrl.text.trim());
      if (!mounted) return;
      // 成功：重置退避，清提示
      setState(() {
        _remote = list;
        _failCount = 0;
        _pollWarning = null;
      });
      if (_autoReceive) _autoFetchNew();
    } catch (_) {
      // ③ 失败：累加失败次数，连续 ≥ kWarnAfterFails 次提示用户。
      if (!mounted) return;
      setState(() {
        _failCount++;
        if (_failCount >= kWarnAfterFails) {
          _pollWarning = '已连续失败 $_failCount 次，请检查视频源是否在线、IP 是否正确';
        }
      });
    } finally {
      // 无论成败，调度下次（失败按退避间隔，成功回基础间隔）。
      _scheduleNextPoll();
    }
  }

  Future<void> _autoFetchNew() async {
    for (final v in _remote) {
      if (_isNew(v) && !_downloading.containsKey(v.name)) {
        await _download(v, auto: true);
      }
    }
  }

  /// ② 下载：指数退避重试 3 次 + 可取消。
  /// 自动接收模式失败静默（不打断用户），手动下载失败弹错误。
  /// 用户主动取消（dio 抛 cancel 异常）始终静默。
  Future<void> _download(RemoteVlog v, {bool auto = false}) async {
    final cancelToken = CancelToken();
    setState(() {
      _downloading[v.name] = null;
      _cancels[v.name] = cancelToken;
    });
    try {
      await retryWithBackoff(
        () => _client.download(
          _ipCtrl.text.trim(),
          v,
          onProgress: (prog) {
            if (mounted) setState(() => _downloading[v.name] = prog);
          },
          cancelToken: cancelToken,
        ),
        maxAttempts: 3,
        // dio 取消异常不重试（用户主动取消）
        shouldRetry: (e) => !_isCancelledByUser(e),
        delay: (d) => Future.delayed(d),
      );
      if (!mounted) return;
      setState(() {
        _downloading.remove(v.name);
        _cancels.remove(v.name);
      });
      await _loadLocalNames();
      _snack('${auto ? "自动接收" : "已下载"}「${v.displayName}」→ 去 Vlog 库播放', ok: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading.remove(v.name);
        _cancels.remove(v.name);
      });
      final cancelled = _isCancelledByUser(e);
      if (!auto && !cancelled) {
        _snack(DeviceClient.describeError(e), ok: false);
      }
      // 用户取消 / 自动接收失败 静默。
    }
  }

  /// dio 取消请求抛 DioException(type: cancel)，与用户主动取消对齐。
  bool _isCancelledByUser(Object e) {
    if (e is DioException) {
      return e.type == DioExceptionType.cancel;
    }
    return false;
  }

  void _cancelDownload(String name) {
    _cancels[name]?.cancel();
  }

  Future<void> _toggleAuto(bool v) async {
    setState(() => _autoReceive = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoReceive, v);
    if (v) {
      _scheduleNextPoll();
      if (_connected) _autoFetchNew();
    } else {
      _pollTimer?.cancel();
    }
  }

  void _snack(String msg, {required bool ok}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: ok ? Colors.green.shade600 : Colors.red.shade600,
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设备')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _connectCard(),
          const SizedBox(height: 12),
          if (_error != null)
            Card(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
              ),
            ),
          if (_pollWarning != null) ...[
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_pollWarning!,
                          style: TextStyle(color: Colors.orange.shade800, fontSize: 13)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_connected) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('自动接收新视频'),
              subtitle: const Text('检测到有新 Vlog 时自动下载到本地'),
              value: _autoReceive,
              onChanged: _toggleAuto,
            ),
            Row(
              children: [
                const Text('可接收的 Vlog', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text('${_remote.length} 个',
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 6),
            if (_remote.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: Text('暂无 Vlog', style: TextStyle(color: Colors.grey))),
              ),
            ..._remote.map(_remoteTile),
          ],
        ],
      ),
    );
  }

  Widget _connectCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('连接视频源', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            const Text('手机与电脑同一网络后，输入电脑后端的地址：',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 12),
            TextField(
              controller: _ipCtrl,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '地址',
                hintText: '如 192.168.43.100:8080',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.computer_outlined),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading ? null : _connect,
                icon: _loading
                    ? const SizedBox(
                        width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.link),
                label: Text(_loading ? '连接中…' : (_connected ? '刷新列表' : '连接')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _remoteTile(RemoteVlog v) {
    final downloading = _downloading.containsKey(v.name);
    final prog = _downloading[v.name];
    final isNew = _isNew(v);
    return Card(
      child: ListTile(
        leading: Icon(Icons.movie_outlined,
            color: isNew ? Theme.of(context).colorScheme.primary : Colors.grey),
        title: Row(
          children: [
            Flexible(child: Text(v.displayName, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (!isNew)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(Icons.check_circle, size: 14, color: Colors.green),
              ),
          ],
        ),
        subtitle: downloading
            ? Row(
                children: [
                  Expanded(child: LinearProgressIndicator(value: prog)),
                  const SizedBox(width: 8),
                  Text(prog != null ? '${(prog * 100).round()}%' : '…',
                      style: const TextStyle(fontSize: 12)),
                ],
              )
            : Text(isNew ? v.sizeText : '已在本地'),
        trailing: downloading
            // ② 下载中显示 ✕，点击取消
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: '取消下载',
                onPressed: () => _cancelDownload(v.name),
              )
            : IconButton(
                icon: Icon(isNew ? Icons.download : Icons.refresh),
                tooltip: isNew ? '下载' : '重新下载',
                onPressed: () => _download(v),
              ),
      ),
    );
  }
}
