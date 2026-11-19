import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/pilot/alarm_pilot.dart';
import 'package:openstrap_edge/pilot/wake_runtime.dart';
void main(){
  // why: prove the real wake tick wires the fail-safe and its cancellation filter.
  // catches: having correct pure policy with no live runtime caller.
  test('runtime arms ahead of workout and cancels only qualifying in-window evidence',()async{
    final arms=<DateTime>[],cancels=<String>[];
    var evidence=<PilotWorkoutEvidence>[];
    final r=PilotWakeRuntime(arm:(at)async{arms.add(at);},cancelWorkout:(id,_)async{cancels.add(id);},workouts:(_,_)async=>evidence,band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true);
    final a=PilotAlarm(id:'run',label:'Run',type:PilotAlarmType.workout,days:{1},workoutStartMinute:1020,wakeMinute:1080,zone:3,zoneMinutes:5);
    await r.tick(now:DateTime(2026,11,23,16),connected:true,alarms:[a]);
    expect(arms,[DateTime(2026,11,23,18)]);
    evidence=[PilotWorkoutEvidence(start:DateTime(2026,11,23,16,59),zoneMinutes:{3:10})];
    await r.tick(now:DateTime(2026,11,23,17,10),connected:true,alarms:[a]);expect(cancels,[]);
    evidence=[PilotWorkoutEvidence(start:DateTime(2026,11,23,17,1),zoneMinutes:{3:3,4:2})];
    await r.tick(now:DateTime(2026,11,23,17,10),connected:true,alarms:[a]);expect(cancels,['run']);
    await r.tick(now:DateTime(2026,11,23,17,11),connected:true,alarms:[a]);expect(cancels,['run']);r.dispose();
  });
  // why: turning off the wake-methods opt-in makes every effect inert.
  // catches: flags gating only UI while the runtime continues sending effects.
  test('runtime off sends no phone band or native commands',()async{
    final calls=<String>[];final r=PilotWakeRuntime(arm:(_)async{calls.add('arm');},cancelWorkout:(_,_)async{calls.add('cancel');},workouts:(_,_)async=>[],band:(_,_)async{calls.add('band');},phone:(_,_)async{calls.add('phone');return true;},isEnabled:()=>false);
    final a=PilotAlarm(id:'a',label:'A',gradual:true,phoneSound:true,sunrise:true);r.noteFire(a,DateTime(2026,11,23,7));
    await r.tick(now:DateTime(2026,11,23,7,1),connected:true,alarms:[a]);expect(calls,[]);expect(r.sunrise.value,0);r.dispose();
  });
  // why: a delivered phone effect, rather than a notification or I'm up, cancels the backup.
  // catches: cancelling only on acknowledgement, or cancelling before delivery succeeds.
  test('app fire at T cancels backup without acknowledgement; failed delivery retains it',()async{
    final at=DateTime(2026,11,23,7),events=<String>[];
    var delivered=false;
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true,
      fireApp:(_,time)async{events.add('fire:$time');return delivered;},cancelBackup:(id,time)async{events.add('cancel:$id:$time');});
    final a=PilotAlarm(id:'a',label:'A',days:{1},band:false,phoneSound:true,soundDelayMinutes:0);
    await r.tick(now:at,connected:true,alarms:[a]);
    expect(events,['fire:$at']);
    delivered=true;await r.tick(now:at.add(const Duration(seconds:30)),connected:true,alarms:[a]);
    expect(events,['fire:$at','fire:${at.add(const Duration(seconds:30))}','cancel:a:$at']);expect(r.acknowledged,false);
    await r.tick(now:at.add(const Duration(seconds:40)),connected:true,alarms:[a]);expect(events.length,3);r.dispose();
  });
  // why: m204's native fallback must survive process death and a disconnected phone.
  // catches: a runtime tick cancelling a backup while the band cannot be reached.
  test('disconnected at T app can fire but cannot cancel native backup',()async{
    final events=<String>[];final at=DateTime(2026,11,23,7);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true,
      fireApp:(_,_)async{events.add('fire');return true;},cancelBackup:(_,_)async{events.add('cancel');});
    await r.tick(now:at,connected:false,alarms:[PilotAlarm(id:'a',label:'A',days:{1},band:false)]);
    expect(events,['fire']);r.dispose();
  });
  // why: m206 anchors escalation to the real fire, even when the preview expected later.
  // catches: measuring all escalation from the forecast or sharing one delay for every step.
  for(final step in ['sound','vibration'])test('$step delay starts at actual fire',()async{
    final effects=<String>[];final fire=DateTime(2026,11,23,6,45);
    final a=PilotAlarm(id:'a',label:'A',days:{1},referenceWakeMinute:420,phoneSound:step=='sound',phoneVibration:step=='vibration',soundDelayMinutes:5,vibrationDelayMinutes:5);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(a,_)async{effects.add(a.phoneSound?'sound':'vibration');return true;},isEnabled:()=>true);
    r.noteFire(a,fire);await r.tick(now:DateTime(2026,11,23,6,46),connected:true,alarms:[a]);expect(effects,[]);
    await r.tick(now:DateTime(2026,11,23,6,50),connected:true,alarms:[a]);expect(effects,[step]);r.dispose();
  });
  // why: without a measured forecast, m206's lead-up is relative to Latest.
  // catches: fixed 30-minute sunrise or refusing a lead-up when forecast is absent.
  test('missing expected wake anchors configurable sunrise to Latest',()async{
    final a=PilotAlarm(id:'a',label:'A',days:{1},sunrise:true,sunriseMinutes:20);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true);
    await r.tick(now:DateTime(2026,11,23,6,35),connected:true,alarms:[a]);expect(r.sunrise.value,0);
    await r.tick(now:DateTime(2026,11,23,6,50),connected:true,alarms:[a]);expect(r.sunrise.value,.5);r.dispose();
  });
  // why: an unexpectedly early wake finishes lead-ups in 30 seconds, never minutes late.
  // catches: continuing the old forecast ramp or replaying its full duration after fire.
  for(final minute in [0,50])test('fire at 06:$minute finishes sunrise in a short ramp',()async{
    final a=PilotAlarm(id:'a',label:'A',days:{1},sunrise:true,sunriseMinutes:20);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(_,_)async{},phone:(_,_)async=>true,isEnabled:()=>true);
    final fire=DateTime(2026,11,23,6,minute);
    await r.tick(now:fire,connected:true,alarms:[a]);final initial=r.sunrise.value;r.noteFire(a,fire);
    await r.tick(now:fire.add(const Duration(seconds:15)),connected:true,alarms:[a]);expect(r.sunrise.value,initial+(1-initial)*.5);
    await r.tick(now:fire.add(const Duration(seconds:31)),connected:true,alarms:[a]);expect(r.sunrise.value,0);r.dispose();
  });
  // why: the early-fire rule applies to gradual band buzzes as well as Sunrise.
  // catches: replaying the whole gradual lead-up after fire or continuing its old forecast.
  test('early fire finishes gradual in one bounded 30-second ramp',()async{
    final durations=<int>[];
    final a=PilotAlarm(id:'a',label:'A',days:{1},gradual:true,gradualMinutes:20);
    final r=PilotWakeRuntime(arm:(_)async{},cancelWorkout:(_,_)async{},workouts:(_,_)async=>[],band:(sequence,_)async{durations.add(sequence.offsetsMs.last+sequence.durationsMs.last);},phone:(_,_)async=>true,isEnabled:()=>true);
    final fire=DateTime(2026,11,23,6);r.noteFire(a,fire);
    await r.tick(now:fire,connected:true,alarms:[a]);expect(durations,[30000]);
    await r.tick(now:fire.add(const Duration(minutes:50)),connected:true,alarms:[a]);expect(durations,[30000]);r.dispose();
  });
}
