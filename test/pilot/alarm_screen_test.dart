import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ble/ble_state.dart' show AlarmBandWriter;

class Band implements AlarmBandWriter {
  final writes=<DateTime>[];
  @override Future<DateTime?> setAlarm(DateTime at) async { writes.add(at); return at; }
  @override Future<bool> disableAlarm() async => true;
}
void main() {
  setUp(() async { SharedPreferences.setMockInitialValues({}); await Prefs.reload(); });
  // why: separate alarm drafts must not leak changes before Save.
  // catches: storing mutable draft instances or saving on field changes.
  test('two alarms retain independent saved drafts', () async {
    final work=PilotAlarm(id:'work',label:'Work',wakeMinute:390);
    final run=PilotAlarm(id:'run',label:'Run',type:PilotAlarmType.workout);
    await PilotAlarmStore.save([work,run]);
    work.wakeMinute=480;
    final saved=await PilotAlarmStore.load();
    expect(saved.map((a)=>a.wakeMinute), [390,420]);
    expect(saved[1].type,PilotAlarmType.workout);
  });
  // why: one arming source even when both stores contain the same alarm.
  // catches: invoking weekly arming as well as pilot arming.
  test('flag on selects one store and arms 06:30 once', () async {
    await PilotFlags.set(PilotFlag.alarmScreen,true);
    await PilotAlarmStore.save([PilotAlarm(id:'a',label:'A',wakeMinute:390,days:{1})]);
    var reads=0;
    Future<List<AlarmScheduleEntry>> production() async {
      reads++; return [const AlarmScheduleEntry(weekday:0,hour:6,minute:30,enabled:true)];
    }
    final band=Band();
    await armNextScheduledOccurrence(engine:band,schedule:await selectedAlarmSchedule(production),currentArmedEpoch:null,now:DateTime(2026,11,22,20));
    expect(reads,0);
    expect(band.writes,[DateTime(2026,11,23,6,30)]);
    await PilotFlags.set(PilotFlag.alarmScreen,false);
    expect((await selectedAlarmSchedule(production)).single.hour,6);
    expect(reads,1);
  });
  // why: workout alarms must never claim primary sleep ownership.
  // catches: persisting an unchecked primary bool for workout alarms.
  test('saving workout cannot make it primary', () async {
    await PilotAlarmStore.save([PilotAlarm(id:'r',label:'Run',type:PilotAlarmType.workout,primary:true)]);
    expect((await PilotAlarmStore.load()).single.primary,false);
  });
  // why: Once must never silently become a weekly alarm.
  // catches: expressing a one-shot as a recurring weekday after it fired.
  test('one-shot is excluded after its exact occurrence', () {
    final at=DateTime(2026,11,23,6,30);
    final a=PilotAlarm(id:'once',label:'Once',days:{},wakeMinute:390,onceEpochSec:at.millisecondsSinceEpoch~/1000);
    expect(pilotNextAt(a,DateTime(2026,11,23,5)),at);
    expect(pilotNextAt(a,DateTime(2026,11,23,7)),null);
  });
  // why: owner m204/m205 require a native fallback even with Band buzz off.
  // catches: phone-only scheduling or arming the backup at the ordinary wake time.
  test('Band off retains a native backup at Latest plus one minute', () async {
    final a=PilotAlarm(id:'phone',label:'Phone',band:false,phoneSound:true,days:{1},wakeMinute:390,earlyMinutes:20);
    final band=Band();
    await armNextScheduledOccurrence(engine:band,schedule:pilotAlarmSchedule([a],wakeMethods:true),currentArmedEpoch:null,now:DateTime(2026,11,23,6));
    expect(band.writes,[DateTime(2026,11,23,6,31)]);
    expect(pilotAlarmSchedule([a],wakeMethods:true).single.naturalWindowMinutes,20);
    a.band=true;expect(nextAlarmOccurrence(pilotAlarmSchedule([a],wakeMethods:true),DateTime(2026,11,23,6)),DateTime(2026,11,23,6,30));
    expect(pilotAlarmSchedule([a],wakeMethods:false).single.minute,30);
  });
}
