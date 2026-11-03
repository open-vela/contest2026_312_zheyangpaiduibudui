import 'package:flutter_test/flutter_test.dart';
import 'package:ai_vlog/utils/polling.dart';

/// ③ 断线退避重连 —— 轮询退避时序的纯函数规格。
void main() {
  group('nextPollDelay', () {
    test('未失败(刚成功)回到基础10秒', () {
      expect(nextPollDelay(failCount: 0), const Duration(seconds: 10));
    });

    test('失败1次下次间隔20秒', () {
      expect(nextPollDelay(failCount: 1), const Duration(seconds: 20));
    });

    test('失败2次下次间隔40秒', () {
      expect(nextPollDelay(failCount: 2), const Duration(seconds: 40));
    });

    test('失败3次封顶60秒', () {
      expect(nextPollDelay(failCount: 3), const Duration(seconds: 60));
    });

    test('失败很多次仍封顶60秒', () {
      expect(nextPollDelay(failCount: 99), const Duration(seconds: 60));
    });

    test('自定义基础与上限也按2的幂递增并封顶', () {
      expect(
        nextPollDelay(
          failCount: 2,
          baseInterval: const Duration(seconds: 5),
          maxInterval: const Duration(seconds: 30),
        ),
        const Duration(seconds: 20), // 5 * 4
      );
      expect(
        nextPollDelay(
          failCount: 3,
          baseInterval: const Duration(seconds: 5),
          maxInterval: const Duration(seconds: 30),
        ),
        const Duration(seconds: 30), // 5 * 8 = 40 → 封顶30
      );
    });
  });

  group('kWarnAfterFails', () {
    test('阈值定义为3次', () {
      expect(kWarnAfterFails, 3);
    });
  });
}
