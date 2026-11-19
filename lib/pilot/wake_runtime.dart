// Owner: PilotWakeRuntime owns due pilot effects on the existing wake tick.
// AppState's arm flight remains the only writer of native alarm state.
import 'package:flutter/foundation.dart';
import '../notify/buzz_sequence.dart';
import 'alarm_pilot.dart';

class PilotWorkoutEvidence {
  const PilotWorkoutEvidence({required this.start,required this.zoneMinutes});
  final DateTime start;
  final Map<int,double> zoneMinutes;
}

// The forecast is replaceable; an unexpectedly early fire finishes its lead-ups
// through this one short-ramp seam (owner m206 and follow-up).
class WakeLeadUpPolicy {
  const WakeLeadUpPolicy({this.finishDuration=const Duration(seconds:30)});
  final Duration finishDuration;
  DateTime expected(PilotAlarm alarm,DateTime latest)=>DateTime(latest.year,latest.month,latest.day,
    (alarm.referenceWakeMinute??alarm.wakeMinute)~/60,(alarm.referenceWakeMinute??alarm.wakeMinute)%60);
  double? afterFire(double initial,Duration elapsed)=>elapsed>finishDuration?null:
    initial+(1-initial)*(elapsed.inMilliseconds/finishDuration.inMilliseconds).clamp(0,1);
}

class PilotWakeRuntime {
  PilotWakeRuntime({required this.arm,required this.cancelWorkout,required this.workouts,
    required this.band,required this.phone,required this.isEnabled,this.fireApp,this.cancelBackup,
    this.leadUps=const WakeLeadUpPolicy()});
  final Future<void> Function(DateTime) arm;
  final Future<void> Function(String,DateTime) cancelWorkout;
  final Future<List<PilotWorkoutEvidence>> Function(DateTime,DateTime) workouts;
  final Future<void> Function(BuzzSequence,String) band;
  final Future<void> Function(PilotAlarm,String) phone;
  final Future<bool> Function(PilotAlarm,DateTime)? fireApp;
  final Future<void> Function(String,DateTime)? cancelBackup;
  final bool Function() isEnabled;
  final WakeLeadUpPolicy leadUps;
  final sunrise=ValueNotifier<double>(0);
  final flash=ValueNotifier<bool>(false);
  final effects=ValueNotifier<int>(0);
  final Map<String,WorkoutFailSafe> _workout={};
  final Set<String> _played={};
  bool _running=false;
  PilotAlarm? firedAlarm;DateTime? firedAt,_firedOccurrence;bool acknowledged=false;
  double _sunriseAtFire=0;
  void noteFire(PilotAlarm? alarm,DateTime at,{DateTime? occurrence}){
    if(!isEnabled()||alarm==null||firedAt==at)return;
    firedAlarm=alarm.copy();firedAt=at;acknowledged=false;_sunriseAtFire=sunrise.value;
    _firedOccurrence=occurrence??pilotNextAt(alarm,at.subtract(const Duration(seconds:1)))??pilotPreviousAt(alarm,at);
    effects.value++;
  }
  void noteSnoozeFire(PilotAlarm alarm,DateTime at)=>noteFire(alarm,at,occurrence:_firedOccurrence);
  void acknowledge(){acknowledged=true;sunrise.value=0;flash.value=false;effects.value++;}
  double lightAt(DateTime now){
    final at=firedAt;
    if(acknowledged)return 0;
    if(at!=null&&firedAlarm?.sunrise==true&&!now.isBefore(at))return leadUps.afterFire(_sunriseAtFire,now.difference(at))??0;
    return sunrise.value;
  }
  Future<bool> appFire(PilotAlarm alarm,DateTime at,{required DateTime occurrence,required bool connected})async{
    final key='${alarm.id}:${occurrence.millisecondsSinceEpoch}:app';
    if(!_played.contains(key)){
      if(await fireApp?.call(alarm,at)!=true)return false;
      _played.add(key);noteFire(alarm,at,occurrence:occurrence);
    }
    await _cancelBackup(alarm,occurrence,connected);
    return true;
  }
  Future<void> _cancelBackup(PilotAlarm alarm,DateTime occurrence,bool connected)async{
    final key='${alarm.id}:${occurrence.millisecondsSinceEpoch}:cancel';
    if(alarm.band||!connected||_played.contains(key))return;
    await cancelBackup?.call(alarm.id,occurrence);_played.add(key);
  }
  Future<void> tick({required DateTime now,required bool connected,required List<PilotAlarm> alarms,bool snoozed=false})async{
    if(_running)return;
    if(!isEnabled()){sunrise.value=0;flash.value=false;return;}
    _running=true;
    try{
      for(final alarm in alarms.where((a)=>a.enabled&&a.type==PilotAlarmType.sleep&&!a.band)){
        final at=pilotPreviousAt(alarm,now);
        if(at!=null&&now.difference(at)<const Duration(hours:3))await appFire(alarm,now,occurrence:at,connected:connected);
      }
      var brightness=0.0;
      var flashing=false;
      for(final alarm in alarms.where((a)=>a.enabled)){
        final end=pilotNextAt(alarm,now);
        if(end==null)continue;
        final key='${alarm.id}:${end.millisecondsSinceEpoch}';
        if(alarm.type==PilotAlarmType.workout){
          final start=workoutWindowStart(alarm,end);
          if(end.difference(now)>const Duration(days:1))continue;
          final failSafe=_workout.putIfAbsent(key,()=>WorkoutFailSafe(_RuntimeWorkoutPort(arm,(e)=>cancelWorkout(alarm.id,e))));
          if(!_played.contains('$key:armed')&&connected){await failSafe.prepare(start,end,previousAcknowledged:acknowledged);_played.add('$key:armed');}
          if(now.isBefore(start)||!connected)continue;
          for(final evidence in await workouts(start,end)){
            final minutes=evidence.zoneMinutes.entries.where((e)=>e.key>=alarm.zone).fold<double>(0,(total,e)=>total+e.value);
            await failSafe.workout(started:evidence.start,zone:alarm.zone,minutes:minutes.floor(),alarm:alarm);
          }
          continue;
        }
        if(firedAlarm?.id==alarm.id&&firedAt!=null&&now.difference(firedAt!)<const Duration(hours:3))continue;
        final expected=leadUps.expected(alarm,end);
        if(alarm.sunrise&&alarm.sunriseMinutes>0){
          final left=expected.difference(now).inSeconds,total=alarm.sunriseMinutes*60;
          if(left>=0&&left<=total)brightness=(1-left/total).clamp(brightness,1);
        }
        if(alarm.gradual&&alarm.band&&connected&&alarm.gradualMinutes>0){
          final start=expected.subtract(Duration(minutes:alarm.gradualMinutes));
          if(!now.isBefore(start)&&now.isBefore(expected)){
            final effect='$key:gradual:${now.difference(start).inSeconds~/60}';
            if(_played.add(effect))await band(BuzzSequence(gradualOffsets(alarm.pattern)),effect);
          }
        }
      }
      final alarm=firedAlarm,at=firedAt;
      
      if(alarm!=null&&at!=null&&!acknowledged&&!now.isBefore(at)&&now.difference(at)<const Duration(hours:3)){
        final elapsed=now.difference(at),key='${alarm.id}:${at.millisecondsSinceEpoch}';
        if(_firedOccurrence!=null)await _cancelBackup(alarm,_firedOccurrence!,connected);
        if(alarm.sunrise)brightness=leadUps.afterFire(_sunriseAtFire,elapsed)??0;
        if(!snoozed&&connected&&alarm.band&&alarm.gradual&&elapsed<=leadUps.finishDuration&&_played.add('$key:finish')){
          // A bounded 30 s hold sequence finishes the lead-up without replaying
          // its multi-minute forecast. The shared haptic queue owns delivery.
          await band(BuzzSequence([0,6000,12000,18000,24000],durationsMs:[4500,4500,4500,4500,6000]),'$key:finish');
        }
        if(!snoozed&&connected&&alarm.band&&alarm.customPatternId!=null&&elapsed>=const Duration(seconds:60)){
          final effect='$key:custom:${elapsed.inSeconds~/60}';
          if(_played.add(effect))await band(BuzzSequence([0],patternId:alarm.customPatternId),effect);
        }
        if(!snoozed){
          flashing=alarm.phoneFlash&&elapsed>=Duration(minutes:alarm.flashDelayMinutes);
          final sound=alarm.phoneSound&&elapsed>=Duration(minutes:alarm.soundDelayMinutes);
          final vibration=alarm.phoneVibration&&elapsed>=Duration(minutes:alarm.vibrationDelayMinutes);
          final effect='$key:phone:${elapsed.inSeconds~/30}';
          if((sound||vibration)&&_played.add(effect)){
            final due=alarm.copy()..phoneSound=sound..phoneVibration=vibration;
            await phone(due,effect);
          }
        }
      }
      sunrise.value=brightness;flash.value=flashing;effects.value++;
    }finally{_running=false;}
  }
  void suspendFlash(){flash.value=false;}
  void dispose(){sunrise.dispose();flash.dispose();effects.dispose();}
}
class _RuntimeWorkoutPort implements WorkoutAlarmPort {
  _RuntimeWorkoutPort(this.armAction,this.cancelAction);
  final Future<void> Function(DateTime) armAction,cancelAction;
  @override Future<void> arm(DateTime end)=>armAction(end);
  @override Future<void> cancel(DateTime end)=>cancelAction(end);
}
