import 'package:flutter_test/flutter_test.dart';
import 'package:dineinapk/utils/async_guard.dart';

void main() {
  test('AsyncGuard leading-edge skips overlapping runs', () async {
    final guard = AsyncGuard();
    var started = 0;
    var finished = 0;

    final first = guard.run(() async {
      started++;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      finished++;
      return 'a';
    });
    final second = guard.run(() async {
      started++;
      finished++;
      return 'b';
    });

    expect(await second, isNull);
    expect(await first, 'a');
    expect(started, 1);
    expect(finished, 1);
  });

  test('AsyncGuard allows a second run after the first completes', () async {
    final guard = AsyncGuard();
    expect(await guard.run(() async => 1), 1);
    expect(await guard.run(() async => 2), 2);
  });
}
