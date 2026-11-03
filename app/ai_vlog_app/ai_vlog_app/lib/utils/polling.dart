/// 轮询退避策略（纯函数，便于单元测试）。
///
/// 用于设备页"自动接收"的定时轮询：成功则回到基础间隔，失败则指数退避，
/// 连续失败达到阈值后向用户提示"请检查连接"。
const int kWarnAfterFails = 3;

/// 计算下次轮询间隔。
///
/// - [failCount] <= 0（刚成功或未失败）：返回 [baseInterval]（默认10s）
/// - [failCount] >= 1：返回 baseInterval * 2^failCount，封顶 [maxInterval]（默认60s）
///   即 1次失败→20s，2次→40s，3次→60s封顶
///
/// 抽成纯函数是为了能脱离 Flutter SDK 用 `dart test` 直接验证退避时序，
/// 与 [retryWithBackoff] 的 [backoffAfter] 区别在于：这里的"间隔"语义是
/// 轮询周期，baseInterval 是正常轮询频率，不是失败后的补偿退避。
Duration nextPollDelay({
  required int failCount,
  Duration baseInterval = const Duration(seconds: 10),
  Duration maxInterval = const Duration(seconds: 60),
}) {
  if (failCount <= 0) return baseInterval;
  final multiplied = baseInterval * (1 << failCount); // 2^failCount
  return multiplied > maxInterval ? maxInterval : multiplied;
}
