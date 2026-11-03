import 'dart:async';

/// 下载/操作被用户主动取消。与 dio 的 cancellation 区分，便于上层判别。
class CancelledException implements Exception {
  const CancelledException();
}

/// 计算第 [attempt] 次失败后的退避时长（attempt 从 1 开始）。
///
/// 纯函数：10s → 20s → 40s → 80s... 封顶 60s。供 [retryWithBackoff] 使用。
/// 抽成纯函数是为了能脱离 Flutter SDK 用 `dart test` 直接验证退避时序。
Duration backoffAfter(int attempt) {
  const base = Duration(seconds: 10);
  const cap = Duration(seconds: 60);
  if (attempt < 1) return base;
  // 1<<0=1, 1<<1=2, 1<<2=4 ... → 10, 20, 40, 80
  final multiplied = base * (1 << (attempt - 1));
  return multiplied > cap ? cap : multiplied;
}

/// 对 [action] 做指数退避重试：最多 [maxAttempts] 次，
/// 失败后按 [backoff] 等待再试。[shouldRetry] 决定异常是否值得重试，
/// [shouldCancel] 在每次尝试前检查，若已取消则抛 [CancelledException]。
///
/// [delay] 默认真实等待，测试可注入立即返回的假函数以跑纯逻辑。
Future<T> retryWithBackoff<T>(
  Future<T> Function() action, {
  int maxAttempts = 3,
  Duration Function(int) backoff = backoffAfter,
  bool Function(Object)? shouldRetry,
  bool Function()? shouldCancel,
  Future<void> Function(Duration) delay = _defaultDelay,
}) async {
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    if (shouldCancel != null && shouldCancel()) {
      throw const CancelledException();
    }
    try {
      return await action();
    } catch (e) {
      final retriable = shouldRetry == null || shouldRetry(e);
      if (!retriable || attempt == maxAttempts) rethrow;
      await delay(backoff(attempt));
    }
  }
  // 不可达：循环要么 return，要么 rethrow。
  throw StateError('unreachable');
}

Future<void> _defaultDelay(Duration d) => Future.delayed(d);
