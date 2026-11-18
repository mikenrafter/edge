// WHY: scheduler/UI notifications are not new sleep work. Waking the nap
// runner from them feeds its release -> snapshot -> notification back to itself.
// CLAIM(sleep-block-one-queue). No timers, sleeps or real DB are needed.
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/sleep_edit_store.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/sleep_edit_runner.dart';
class _EmptyQueue implements SleepEditQueue {
  int reads=0;
  @override
  Future<List<SleepEditJob>> pending({bool retryFailed=false}) async { reads++;return []; }
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
      } finally { app.dispose();clock.flushMicrotasks(); }
    });
  });
}
