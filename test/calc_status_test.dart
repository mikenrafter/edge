// P4b: the process-wide calculation status (stack semantics).
//
// ASSUMED API (new file lib/compute/calc_status.dart):
//
//   class CalcStep {
//     final String label;        // plain words: "Sleep stages"
//     final DateTime startedAt;  // from the status's clock
//   }
//
//   class CalcStatus implements ValueListenable<CalcStep?> {
//     CalcStatus({DateTime Function()? clock});   // default DateTime.now
//     static final CalcStatus instance;           // the one process-wide
//
//     CalcStep? get value;          // the MOST RECENT still-open step, or null
//     <token> begin(String label);  // opens a step; the token is opaque
//     void end(<token> token);      // closes THAT step wherever it sits in the
//                                   // stack; unknown / already-ended token is a
//                                   // no-op (never throws)
//     Future<T> run<T>(String label, Future<T> Function() body);
//                                   // begin; await body; end in `finally` (a
//                                   // throw is rethrown AFTER the step is
//                                   // popped); returns body's value
//   }
//
// SEMANTICS pinned here:
//   * nested: the inner step is visible; when it ends the outer shows again
//     with its ORIGINAL startedAt (its elapsed time kept counting).
//   * parallel / out of order: ending a step that is not on top leaves the
//     visible one alone; the visible step is always the most recent one that
//     is still open.
//   * a listener sees every change of the visible step and nothing else.
//
// Failure mode today: the library does not exist (the file fails to load).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/calc_status.dart';

void main() {
  late DateTime now;
  late CalcStatus status;
  late List<String?> seen;

  setUp(() {
    now = DateTime(2026, 10, 4, 9, 0, 0);
    status = CalcStatus(clock: () => now);
    seen = [];
    status.addListener(() => seen.add(status.value?.label));
  });

  test('idle: nothing is open', () {
    expect(status.value, isNull);
  });

  test('begin shows the label and the start time; end hides it', () {
    final t = status.begin('Sleep stages');
    expect(status.value!.label, 'Sleep stages');
    expect(status.value!.startedAt, now);
    status.end(t);
    expect(status.value, isNull);
    expect(seen, ['Sleep stages', null]);
  });

  test('nested: the inner step shows, then the outer returns with its own '
      'start time', () {
    final outer = status.begin('Day calculations');
    final t0 = now;
    now = now.add(const Duration(seconds: 30));
    final inner = status.begin('Sleep stages');
    expect(status.value!.label, 'Sleep stages');
    expect(status.value!.startedAt, now);

    now = now.add(const Duration(seconds: 12));
    status.end(inner);
    expect(status.value!.label, 'Day calculations');
    expect(status.value!.startedAt, t0,
        reason: 'the outer step has been running since it began');
    status.end(outer);
    expect(status.value, isNull);
    expect(seen, ['Day calculations', 'Sleep stages', 'Day calculations', null]);
  });

  test('parallel: the most recent open step is the visible one', () {
    final a = status.begin('Preparing Beats');
    final b = status.begin('Preparing Wellness');
    final c = status.begin('Correcting beats');
    expect(status.value!.label, 'Correcting beats');
    status.end(c);
    expect(status.value!.label, 'Preparing Wellness');
    status.end(b);
    expect(status.value!.label, 'Preparing Beats');
    status.end(a);
    expect(status.value, isNull);
  });

  test('end out of order: closing a step under the top leaves the top alone; '
      'closing the top reveals the next one still open', () {
    final a = status.begin('A');
    final b = status.begin('B');
    final c = status.begin('C');
    seen.clear();

    status.end(a); // not visible
    expect(status.value!.label, 'C');
    expect(seen, isEmpty, reason: 'the visible step did not change');

    status.end(c);
    expect(status.value!.label, 'B', reason: 'A is gone, B is the next open');
    status.end(b);
    expect(status.value, isNull);
  });

  test('ending the same token twice, or a stranger, changes nothing and '
      'does not throw', () {
    final a = status.begin('A');
    final b = status.begin('B');
    status.end(b);
    expect(() => status.end(b), returnsNormally);
    expect(status.value!.label, 'A', reason: 'the second end did not pop A');
    status.end(a);
    expect(() => status.end(a), returnsNormally);
    expect(status.value, isNull);

    final other = CalcStatus(clock: () => now).begin('elsewhere');
    final keep = status.begin('Keep');
    expect(() => status.end(other), returnsNormally);
    expect(status.value!.label, 'Keep');
    status.end(keep);
  });

  test('two steps with the same label are two steps', () {
    final a = status.begin('Same');
    final b = status.begin('Same');
    status.end(b);
    expect(status.value!.label, 'Same', reason: 'the first is still open');
    status.end(a);
    expect(status.value, isNull);
  });

  test('run: open while the body awaits, closed after, value passed through',
      () async {
    String? during;
    final v = await status.run<int>('Baselines', () async {
      await Future<void>.delayed(Duration.zero);
      during = status.value?.label;
      return 7;
    });
    expect(v, 7);
    expect(during, 'Baselines');
    expect(status.value, isNull);
  });

  test('run: a throw inside the section still pops it, and is rethrown',
      () async {
    final outer = status.begin('Outer');
    await expectLater(
      status.run<void>('Inner', () async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('boom');
      }),
      throwsA(isA<StateError>()),
    );
    expect(status.value!.label, 'Outer',
        reason: 'the failed step is popped; the outer one is untouched');
    status.end(outer);
    expect(status.value, isNull);
  });

  test('run: a synchronous throw from the body also pops', () async {
    await expectLater(
      status.run<void>('Inner', () => throw StateError('sync')),
      throwsA(isA<StateError>()),
    );
    expect(status.value, isNull);
  });

  test('run: parallel sections finishing in the opposite order', () async {
    final slow = Future<void>.delayed(const Duration(milliseconds: 30));
    final f1 = status.run<void>('First', () => slow);
    final f2 = status.run<void>('Second', () async {});
    await f2;
    expect(status.value!.label, 'First',
        reason: 'the later one finished first; the earlier one is still open');
    await f1;
    expect(status.value, isNull);
  });

  test('the process-wide instance is one object', () {
    expect(identical(CalcStatus.instance, CalcStatus.instance), isTrue);
    expect(CalcStatus.instance.value, isNull);
  });
}
