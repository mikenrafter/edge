// why: pilot opt-in must retain an existing weekly wake until a sleep alarm exists;
// a notification alone cannot replace a native wake, and restart must not re-fire.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/data/activity_store.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/pilot_flags.dart';
import 'package:openstrap_edge/pilot/wake_runtime.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/util/callable.dart';
import '../support/fake_alarm_engine.dart';
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll((){sqfliteFfiInit();databaseFactory=databaseFactoryFfi;LocalDb.dbName='pilot_safety_followup.db';});
  setUp(()async{await LocalDb.close();await databaseFactory.deleteDatabase('${await databaseFactory.getDatabasesPath()}/${LocalDb.dbName}');SharedPreferences.setMockInitialValues({});await Prefs.reload();await PilotFlags.set(PilotFlag.alarmScreen,true);await PilotFlags.set(PilotFlag.wakeMethods,true);});
  tearDownAll(()async{await LocalDb.close();await databaseFactory.deleteDatabase('${await databaseFactory.getDatabasesPath()}/${LocalDb.dbName}');});
  final latest=DateTime(2026,11,23,7);
  // catches: selecting an empty pilot schedule and sending disableAlarm.
  test('pilot on with no enabled pilot sleep alarm retains the weekly native arm',()async{
    await LocalDb.setAlarmScheduleRows([const AlarmScheduleEntry(weekday:0,hour:6,minute:30).toRow()]);
    for(final alarms in [<PilotAlarm>[],[PilotAlarm(id:'off',label:'Off',enabled:false)],[PilotAlarm(id:'run',label:'Run',type:PilotAlarmType.workout)]]){
      await PilotAlarmStore.save(alarms);final band=FakeAlarmEngine(),live=AppState.forTesting(engine:band);live.debugWakeClock=()=>DateTime(2026,11,23,6);
      try{await live.debugArmNextAlarmOccurrence();expect(band.sets.map((at)=>[at.hour,at.minute]),[[6,30]]);}finally{live.dispose();}
    }
  });
  // catches: SystemSound.alert, which never reaches Android's ringtone bridge.
  test('Phone sound calls the existing ring_phone device action',()async{
    final calls=<MethodCall>[];const channel=MethodChannel('openstrap/device_actions');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{calls.add(call);return true;});
    addTearDown(()=>TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null));
    final live=AppState.forTesting(engine:FakeAlarmEngine()),alarm=PilotAlarm(id:'a',label:'A',phoneSound:true,soundDelayMinutes:0);
    try{live.pilotWake.noteFire(alarm,latest);await live.pilotWake.tick(now:latest,connected:true,alarms:[alarm]);expect(calls.where((c)=>c.method=='perform').map((c)=>(c.arguments as Map)['action']),contains('ring_phone'));}finally{live.dispose();}
  });
  // catches: accepting a Band-off configuration with nothing that can wake the wearer.
  test('save rejects Band off with no deliverable phone method',()async{
    await expectLater(PilotAlarmStore.save([PilotAlarm(id:'a',label:'A',band:false)]),throwsFormatException);
    for(final method in ['sound','vibration','flash']){await PilotAlarmStore.save([PilotAlarm(id:'a',label:'A',band:false,phoneSound:method=='sound',phoneVibration:method=='vibration',phoneFlash:method=='flash')]);}
  });
  // catches: treating a successful notification post as a delivered wake effect.
  test('notification alone keeps backup while delayed sound has not started',()async{
    final cancels=<String>[];final a=PilotAlarm(id:'a',label:'A',band:false,days:{1},phoneSound:true,soundDelayMinutes:5);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async{},fireApp:(_,_)async=>true,cancelBackup:(id,_)async{cancels.add(id);},isEnabled:()=>true);
    try{await r.tick(now:latest,connected:true,alarms:[a]);expect(r.firedAt,latest);expect(cancels,isEmpty);}finally{r.dispose();}
  });
  // catches: an in-memory played set that forgets the occurrence on process restart.
  test('restart after a Band off fire does not fire that occurrence again',()async{
    final fire=CountingFire(),alarm=PilotAlarm(id:'a',label:'A',band:false,phoneSound:true,days:{1});
    for(final delay in [0,30]){final live=AppState.forTesting(engine:FakeAlarmEngine());live.debugPilotAppFire=fire;
      try{await live.pilotWake.tick(now:latest.add(Duration(minutes:delay)),connected:false,alarms:[alarm]);}finally{live.dispose();}}
    expect(fire.count,1);
  });
  // catches: pilot-only details_json bookkeeping or restore re-encoding the original bytes.
  test('discard and Restore preserve production details bytes and undo only an unlogged absence',()async{
    final db=await LocalDb.instance,store=ActivityStore(await LocalDb.instance);
    await db.insert('track_definition',{'id':'test-track','payload_json':'{}'});
    const details='{ "prompt": true, "track_id": "test-track" }';
    for(final pilot in [false,true]){
      await PilotFlags.set(PilotFlag.timelines,pilot);
      final id=pilot?'pilot':'production';
      await db.insert('activity_suggestions',{'id':id,'kind':'track','day_id':'2026-11-23','start_ts':1,'end_ts':2,'detection_start':1,'detection_end':2,'details_json':details,'status':'pending','revision':0,'created_at':1,'updated_at':1});
      await store.discard((await store.get(id))!);
      expect((await db.query('activity_suggestions',where:'id = ?',whereArgs:[id])).single['details_json'],details);
      if(pilot){final discarded=(await store.get(id))!;await db.transaction((tx)=>ActivityStore.restorePilot(tx,discarded));expect(await db.query('track_absence'),isEmpty);expect((await db.query('activity_suggestions',where:'id = ?',whereArgs:[id])).single['details_json'],details);}
      else{await db.delete('track_absence');}
    }
  });
}
class CountingFire implements Call2<PilotAlarm,DateTime,Future<bool>>{int count=0;@override Future<bool> call(PilotAlarm a,DateTime at)async{count++;return true;}}
