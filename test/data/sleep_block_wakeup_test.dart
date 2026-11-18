// WHY: scheduler/UI notifications are not new sleep work. Waking the nap
// runner from them feeds its release -> snapshot -> notification back to itself.
// CLAIM(sleep-block-one-queue). No timers, sleeps or real DB are needed.
import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';
class _EmptyQueue implements SleepEditQueue {
  int reads=0;
  @override
  Future<List<SleepEditJob>> pending({bool retryFailed=false}) async {
    reads++;
    // Bound a broken feedback loop so the regression fails at the read count.
    if(reads>=3) return Completer<List<SleepEditJob>>().future;
    return [];
  }
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a scheduler notification never wakes the sleep queue',() {
    fakeAsync((clock) {
      final queue=_EmptyQueue();
      final app=AppState.forTesting()..debugSleepEditQueue=queue;
      try {
        app.debugDeriveScheduler.setPowerHold(true);
        clock.flushMicrotasks();
        expect(queue.reads,0);
        var finished=false;
        app.sleepEditRunner.start().then((_) { finished=true; });
        clock.flushMicrotasks();
        expect(queue.reads,2,reason:'the probe observes acquisition and the final outstanding check');
        expect(finished,true);
      } finally { app.dispose();clock.flushMicrotasks(); }
    });
  });
}
