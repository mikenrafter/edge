import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import '../support/fake_alarm_engine.dart';
import 'package:openstrap_edge/util/callable.dart';
import 'package:openstrap_edge/wake/wake_outcome.dart';
import '../alarm_snooze/snooze_fakes.dart' show MemorySnoozeStore;
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(()async{sqfliteFfiInit();databaseFactory=databaseFactoryFfi;LocalDb.dbName='pilot_alarm_owner.db';await LocalDb.close();});
  tearDownAll(()async{await LocalDb.close();await databaseFactory.deleteDatabase('${await databaseFactory.getDatabasesPath()}/${LocalDb.dbName}');});
  setUp((){TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('openstrap/device_actions'),(call)async=>true);});
  tearDown((){TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('openstrap/device_actions'),null);});
  // why: the real foreground arm flight must select the pilot source exactly once.
  // catches: retaining a weekly arm pass beside the pilot store's write.
  test('real AppState arm deduplicates both stores at 06:30 and restores weekly untouched',()async{
    SharedPreferences.setMockInitialValues({});await Prefs.reload();
    final weekly=[for(var d=0;d<7;d++)AlarmScheduleEntry(weekday:d,hour:6,minute:30)];
    await LocalDb.setAlarmScheduleRows([for(final e in weekly)e.toRow()]);
    await PilotAlarmStore.save([PilotAlarm(id:'work',label:'Work',wakeMinute:390,days:{1,2,3,4,5,6,7})]);
    await PilotFlags.set(PilotFlag.alarmScreen,true);
    final band=FakeAlarmEngine();
    final live=AppState.forTesting(engine:band);
    try{
      await Future.wait([live.debugArmNextAlarmOccurrence(),live.debugArmNextAlarmOccurrence()]);
      expect(band.sets.length,1);expect(band.sets.single.hour,6);expect(band.sets.single.minute,30);
      final rows=await LocalDb.alarmScheduleRows();expect(rows.map((r)=>r['hour']),List.filled(7,6));expect(rows.map((r)=>r['minute']),List.filled(7,30));
      await PilotFlags.set(PilotFlag.alarmScreen,false);await live.debugArmNextAlarmOccurrence();expect(band.sets.length,1);
    }finally{live.dispose();}
  });
  // why: m204/m205's fallback is a native clock arm, not a phone timer.
  // catches: no backup after process death, cancelling while disconnected, or waiting for I'm up.
  for(final mode in ['killed','disconnected','alive'])test('Band off backup with app $mode at T',()async{
    SharedPreferences.setMockInitialValues({});await Prefs.reload();
    await PilotFlags.set(PilotFlag.alarmScreen,true);await PilotFlags.set(PilotFlag.wakeMethods,true);
    final latest=DateTime(2026,11,23,7);
    await PilotAlarmStore.save([PilotAlarm(id:'phone',label:'Phone',days:{1},band:false,phoneSound:true,soundDelayMinutes:0)]);
    final band=NativeClockBand();final live=AppState.forTesting(engine:band);var now=latest.subtract(const Duration(hours:1));
    live.debugWakeClock=()=>now;live.debugPilotAppFire=const AcceptAppFire();
    var disposed=false;
    try{
      await live.debugArmNextAlarmOccurrence();expect(band.armed,DateTime(2026,11,23,7,1));
      now=latest;
      if(mode=='killed'){live.dispose();disposed=true;}
      else{if(mode=='disconnected')band.state.connection='disconnected';await live.debugKeepAliveTick();if(mode=='alive')await live.debugArmNextAlarmOccurrence();}
      band.advanceTo(DateTime(2026,11,23,7,1));
      expect(band.buzzes,mode=='alive'?[]:[DateTime(2026,11,23,7,1)]);
      if(mode=='alive'){
        expect(live.pilotWake.acknowledged,false);
        expect(band.armed,DateTime(2026,11,30,7,1));
        final selected=await selectedAlarmSchedule(()async=>throw StateError('production must not be read'),at:latest);
        expect(nextAlarmOccurrence(selected,latest),DateTime(2026,11,30,7,1));
      }
    }finally{if(!disposed)live.dispose();}
  });  // why: cancelling Latest after early fire must not remove the killed-app snooze fallback.
  // catches: app-driven snooze with no native slot or arming the old Latest instead.
  for(final bandOn in [true,false])test('early fire then snooze then killed app retains one native deadline, Band $bandOn',()async{
    SharedPreferences.setMockInitialValues({});await Prefs.reload();await PilotFlags.set(PilotFlag.alarmScreen,true);await PilotFlags.set(PilotFlag.wakeMethods,true);
    final latest=DateTime(2026,11,23,7),alarm=PilotAlarm(id:'a',label:'A',days:{1},band:bandOn,phoneSound:true,soundDelayMinutes:0,earlyMinutes:30);
    await PilotAlarmStore.save([alarm]);final band=NativeClockBand(),live=AppState.forTesting(engine:band);var now=DateTime(2026,11,23,6);
    live.debugWakeClock=()=>now;live.debugPilotAppFire=const AcceptAppFire();live.debugSnoozePlay=(_,{notes,onFirstWrite})async{onFirstWrite?.call();return true;};live.debugSnoozeConfirmedWake=()async=>false;live.debugSnoozeStore=MemorySnoozeStore();
    var disposed=false;
    try{
      await live.debugArmNextAlarmOccurrence();now=DateTime(2026,11,23,6,45);
      await live.pilotWake.appFire(alarm,now,occurrence:latest,connected:true);
      await live.pilotWake.tick(now:now,connected:true,alarms:[alarm]);
      expect(band.armed,bandOn?latest:DateTime(2026,11,30,7,1));
      await live.snoozePilotAlarm();final due=bandOn?latest:DateTime(2026,11,23,6,55);
      if(bandOn){live.wake.noteWakeAwaitingAck(latest.millisecondsSinceEpoch~/1000,WakePath.natural);await live.wake.acknowledgeWake(cancelNative:true);}
      expect(band.armed,due);expect(band.maxInFlight,1);
      live.dispose();disposed=true;band.advanceTo(due);expect(band.buzzes,[due]);
    }finally{if(!disposed)live.dispose();}
  });
  // why: I'm up clears only a Band-off snooze backup, not the next weekly alarm.
  // catches: clearing runtime state but leaving the snooze native slot armed.
  test('Band off I am up clears the pending snooze backup',()async{
    SharedPreferences.setMockInitialValues({});await Prefs.reload();await PilotFlags.set(PilotFlag.alarmScreen,true);await PilotFlags.set(PilotFlag.wakeMethods,true);
    final alarm=PilotAlarm(id:'a',label:'A',days:{1},band:false,phoneSound:true,soundDelayMinutes:0),latest=DateTime(2026,11,23,7);
    await PilotAlarmStore.save([alarm]);final band=NativeClockBand(),live=AppState.forTesting(engine:band);var now=DateTime(2026,11,23,6);
    live.debugWakeClock=()=>now;live.debugPilotAppFire=const AcceptAppFire();live.debugSnoozePlay=(_,{notes,onFirstWrite})async{onFirstWrite?.call();return true;};live.debugSnoozeConfirmedWake=()async=>false;live.debugSnoozeStore=MemorySnoozeStore();
    try{
      await live.debugArmNextAlarmOccurrence();now=DateTime(2026,11,23,6,45);await live.pilotWake.appFire(alarm,now,occurrence:latest,connected:true);
      await live.pilotWake.tick(now:now,connected:true,alarms:[alarm]);
      await live.snoozePilotAlarm();expect(band.armed,DateTime(2026,11,23,6,55));
      await live.wake.acknowledgeWake(cancelNative:true);await live.debugArmNextAlarmOccurrence();
      expect(band.armed,DateTime(2026,11,30,7,1));expect(await PilotSnoozeSlot.load(),null);
      band.advanceTo(DateTime(2026,11,23,6,55));expect(band.buzzes,[]);
    }finally{live.dispose();}
  });

}

// The fake firmware clock deliberately runs without AppState or a phone tick.
class NativeClockBand extends FakeAlarmEngine {
  DateTime? armed;final List<DateTime> buzzes=[];
  @override Future<DateTime?> setAlarm(DateTime when,{int index=0,List<int>? haptics})async{final result=await super.setAlarm(when,index:index,haptics:haptics);if(result!=null)armed=result;return result;}
  @override Future<bool> disableAlarm({int? id})async{armed=null;return super.disableAlarm(id:id);}
  void advanceTo(DateTime time){final at=armed;if(at!=null&&!time.isBefore(at)){buzzes.add(at);armed=null;}}
}

class AcceptAppFire implements Call2<PilotAlarm,DateTime,Future<bool>> {
  const AcceptAppFire();
  @override Future<bool> call(PilotAlarm alarm,DateTime at)async=>true;
}
