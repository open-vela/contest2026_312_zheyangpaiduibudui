import 'package:flutter_test/flutter_test.dart';
import 'package:ai_vlog/utils/retry.dart';

/// ② 下载重试+可取消 —— 退避时序与重试决策的纯函数规格。
///
/// 这部分是纯 dart 逻辑，理论上 `dart test test/retry_test.dart` 即可跑
/// （无需 Flutter SDK），但当前环境连 dart SDK 也没有，仍待装环境验证。
void main() {
  group('backoffAfter', () {
    test('第1次失败退避10秒', () {
      expect(backoffAfter(1), const Duration(seconds: 10));
    });
    test('第2次失败退避20秒', () {
      expect(backoffAfter(2), const Duration(seconds: 20));
    });
    test('第3次失败退避40秒', () {
      expect(backoffAfter(3), const Duration(seconds: 40));
    });
    test('第4次封顶60秒', () {
      expect(backoffAfter(4), const Duration(seconds: 60));
    });
    test('极大次数仍封顶60秒', () {
      expect(backoffAfter(100), const Duration(seconds: 60));
    });
  });

  group('retryWithBackoff', () {
    // 注入立即返回的假 delay，跑纯逻辑不等真实时间。
    Future<void> noDelay(Duration d) async {}

    test('前N-1次失败第N次成功则返回成功值且调用N次', () async {
      var calls = 0;
      final result = await retryWithBackoff(
        () async {
          calls++;
          if (calls < 3) throw Exception('fail');
          return 'ok';
        },
        maxAttempts: 3,
        delay: noDelay,
      );
      expect(result, 'ok');
      expect(calls, 3);
    });

    test('全部失败则抛最后一次异常且调用maxAttempts次', () async {
      var calls = 0;
      await expectLater(
        retryWithBackoff(
          () async {
            calls++;
            throw Exception('always fail');
          },
          maxAttempts: 3,
          delay: noDelay,
        ),
        throwsA(isA<Exception>()),
      );
      expect(calls, 3);
    });

    test('shouldRetry返回false则不重试立即抛出且只调用1次', () async {
      var calls = 0;
      await expectLater(
        retryWithBackoff(
          () async {
            calls++;
            throw FormatException('nope');
          },
          maxAttempts: 3,
          shouldRetry: (e) => e is! FormatException,
          delay: noDelay,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(calls, 1);
    });

    test('shouldCancel在首次尝试前已true则抛CancelledException且不调用action', () async {
      var calls = 0;
      await expectLater(
        retryWithBackoff(
          () async {
            calls++;
            throw Exception('fail');
          },
          maxAttempts: 3,
          shouldCancel: () => true,
          delay: noDelay,
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(calls, 0);
    });

    test('退避期间取消则下次循环抛CancelledException', () async {
      var calls = 0;
      var cancelled = false;
      await expectLater(
        retryWithBackoff(
          () async {
            calls++;
            throw Exception('first fail'); // 第一次必失败
          },
          maxAttempts: 3,
          shouldCancel: () => cancelled,
          delay: (d) async {
            cancelled = true; // 退避期间用户取消
          },
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(calls, 1);
    });
  });
}
