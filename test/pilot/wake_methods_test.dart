import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
class Port implements WorkoutAlarmPort {
  final arms=<DateTime>[], cancellations=<DateTime>[];
  @override Future<void> arm(DateTime end) async { arms.add(end); }
  @override Future<void> cancel(DateTime end) async { cancellations.add(end); }
}
void main() {
  // why: gradual can precede the natural wake window (owner m155).
  // catches: clamping gradual start to the window opening.
  test('gradual is relative to expected wake and independent of early range', () {
    final a=PilotAlarm(id:'a',label:'A',wakeMinute:420,earlyMinutes:10,gradual:true,gradualMinutes:45);
    expect(a.gradualStart(415),370);
    expect(a.gradualStart(null),375); // Latest 420 - 45 min when forecast is absent (m206).
  });
  // why: custom wake patterns need a live phone; the native alarm remains the fallback.
  // catches: advertising custom playback while disconnected.
  test('band default survives disconnect', () {
    final a=PilotAlarm(id:'a',label:'A',customPatternId:'mine');
    expect(bandPatternFor(a,connected:false),'default');
    expect(bandPatternFor(a,connected:true),'mine');
  });
  // why: randomness grows across snoozes (owner m161).
  // catches: using a fixed jitter on every snooze.
  test('chaos increases each snooze and steady stays zero', () {
    expect(chaosSpreadMilliseconds(SnoozeChaos.steady,3),0);
    expect(chaosSpreadMilliseconds(SnoozeChaos.little,1),100);
    expect(chaosSpreadMilliseconds(SnoozeChaos.little,3),300);
    expect(chaosSpreadMilliseconds(SnoozeChaos.wild,3),1500);
  });
  for(final acknowledged in [true,false]) {
    // why: fail-safe arming never depends on the previous alarm acknowledgement.
    // catches: waiting for I'm up or ALARM_SET before arming the workout deadline.
    test('disconnected whole window keeps native deadline, previous ack $acknowledged', () async {
      final p=Port(), start=DateTime(2026,11,23,17), end=DateTime(2026,11,23,18);
      await WorkoutFailSafe(p).prepare(start,end,previousAcknowledged:acknowledged);
      expect(p.arms,[end]); expect(p.cancellations,[]);
    });
  }
  // why: only an in-window qualifying workout cancels the future band alarm.
  // catches: treating an already-running workout as in-window evidence.
  test('qualifying workout inside cancels; before window does not', () async {
    final p=Port(), start=DateTime(2026,11,23,17), end=DateTime(2026,11,23,18);
    final f=WorkoutFailSafe(p), a=PilotAlarm(id:'r',label:'Run',type:PilotAlarmType.workout,zone:3,zoneMinutes:5);
    await f.prepare(start,end,previousAcknowledged:false);
    await f.workout(started:start.subtract(const Duration(minutes:1)),zone:4,minutes:10,alarm:a);
    expect(p.cancellations,[]);
    await f.workout(started:start.add(const Duration(minutes:5)),zone:3,minutes:5,alarm:a);
    expect(p.cancellations,[end]);
  });
}
