import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:audiobook_app/narration_seek.dart';

void main() {
  late Duration current;
  late Duration? total;
  late bool active;
  late int loads, pauses, seeks, waits;
  late Future<void> Function(Duration) seek;
  late Future<void> Function(Duration) wait;
  setUp(() {
    current = const Duration(seconds: 90);
    total = const Duration(seconds: 100);
    active = true;
    loads = pauses = seeks = waits = 0;
    seek = (target) async { seeks++; current = target; };
    wait = (_) async { waits++; };
  });
  Future<bool> run(double fraction, {Future<void> Function()? load}) => seekNarrationFromText(
    fraction: fraction, load: load ?? () async { loads++; },
    pause: () async { pauses++; }, seek: (target) => seek(target),
    duration: () => total, position: () => current,
    isCurrent: () => active, wait: (delay) => wait(delay),
  );
  test('new source prepares and seeks; already loaded source still seeks', () async {
    await run(.4);
    expect(current, const Duration(seconds: 40));
    current = const Duration(seconds: 90);
    await run(.2, load: () async {});
    expect(current, const Duration(seconds: 20));
    expect(loads, 1);
    expect(pauses, 2);
  });
  test('waits for delayed positive duration metadata', () async {
    total = Duration.zero;
    wait = (_) async { waits++; if (waits == 3) total = const Duration(seconds: 100); };
    expect(await run(.3), isTrue);
    expect(waits, 3);
    expect(current, const Duration(seconds: 30));
  });
  test('zero target works without duration; near-zero seeks also retry', () async {
    total = null;
    expect(await run(0), isTrue);
    expect(current, Duration.zero);
    total = const Duration(seconds: 100);
    current = const Duration(seconds: 90);
    seeks = 0;
    seek = (target) async { seeks++; if (seeks == 2) current = target; };
    expect(await run(.005), isTrue);
    expect(seeks, 2);
    expect(current, const Duration(milliseconds: 500));
  });
  test('transient exceptions retry and silent failures are reported', () async {
    seek = (target) async { seeks++; if (seeks == 1) throw StateError('decoder'); current = target; };
    expect(await run(.5), isTrue);
    expect(seeks, 2);
    seeks = 0;
    seek = (_) async { seeks++; };
    await expectLater(run(.1), throwsA(isA<StateError>().having((e) => e.message, 'message', contains('after 3 attempts'))));
    expect(seeks, 3);
  });
  test('permanent seek exceptions and missing metadata are bounded failures', () async {
    seek = (_) async { seeks++; throw StateError('decoder'); };
    await expectLater(run(.5), throwsStateError);
    expect(seeks, 3);
    total = null;
    seeks = 0;
    await expectLater(run(.5), throwsStateError);
    expect(seeks, 0);
    expect(waits, 40);
  });
  test('navigation cancels before load, after load, and during metadata/retry waits', () async {
    active = false;
    expect(await run(.5), isFalse);
    expect(loads, 0);
    active = true;
    expect(await run(.5, load: () async { active = false; }), isFalse);
    expect(pauses, 0);
    active = true;
    total = null;
    wait = (_) async { active = false; };
    expect(await run(.5), isFalse);
    expect(seeks, 0);
    active = true;
    total = const Duration(seconds: 100);
    seek = (_) async { seeks++; };
    expect(await run(.5), isFalse);
    expect(seeks, 1);
  });
  test('late player position is observed before retrying', () async {
    seek = (_) async { seeks++; };
    wait = (_) async { waits++; if (waits == 3) current = const Duration(seconds: 50); };
    expect(await run(.5), isTrue);
    expect(seeks, 1);
  });
  testWidgets('hung native seek times out without overlapping retries', (tester) async {
    seek = (_) { seeks++; return Completer<void>().future; };
    final result = expectLater(run(.5), throwsStateError);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await result;
    expect(seeks, 1);
  });
}
