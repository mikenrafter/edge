part of '../app_state.dart';

// AppState owns the live wake state; this adapter binds its existing transports
// and single native arm flight to the isolated pilot runtime.
extension _AppPilotWake on AppState {
  PilotWakeRuntime _createPilotWake()=>PilotWakeRuntime(
    isEnabled:()=>!_disposed&&_pilotWakeOn,
    fireApp:_deliverPilotApp,
    cancelBackup:(id,latest)async{
      final prefs=await SharedPreferences.getInstance();
      if(!await prefs.setInt('pilot.backup.cancelled.$id',latest.add(const Duration(minutes:1)).millisecondsSinceEpoch~/1000))throw StateError('Backup cancellation was not saved');
      // Replacing this occurrence uses the same serialized writer as every arm.
      // A failed radio write leaves the native backup intact and is retried.
      final result=await _armNextAlarmOccurrence();if(result.failed)throw StateError('Backup cancellation did not reach the band');
    },
    arm:(_)async{await _armNextAlarmOccurrence();},
    cancelWorkout:(id,end)async{
      final prefs=await SharedPreferences.getInstance();
      if(!await prefs.setInt('pilot.workout.completed.$id',end.millisecondsSinceEpoch~/1000))throw StateError('Workout completion was not saved');
      await _armNextAlarmOccurrence();
    },
    workouts:(start,end)async{
      final rows=await repo?.getSessions(from:start.millisecondsSinceEpoch~/1000,to:end.millisecondsSinceEpoch~/1000,includeDetected:false)??[];
      final out=<PilotWorkoutEvidence>[];
      for(final row in rows){
        final stamp=row['start_ts'],zones=row['zone_min'];
        if(stamp is! num||zones is! List)continue;
        out.add(PilotWorkoutEvidence(start:DateTime.fromMillisecondsSinceEpoch(stamp.toInt()*1000),zoneMinutes:{for(var i=0;i<zones.length;i++)if(zones[i] is num)i+1:(zones[i] as num).toDouble()}));
      }
      final active=activeWorkout;
      if(active!=null)out.add(PilotWorkoutEvidence(start:active.startTime,zoneMinutes:{for(var i=0;i<active.zoneSeconds.length;i++)i:active.zoneSeconds[i]/60}));
      return out;
    },
    band:(sequence,event)async{
      var play=sequence;
      if(sequence.patternId!=null){
        final saved=(await HapticPatternStore.load()).byId(sequence.patternId!);
        if(saved==null)return;play=saved.sequence;
      }
      await _dispatchBandAlert('wake',sequence:play,eventId:event,transportTargets:const {'band'},deliver:(rhythm,_)=>haptics.deliver(play));
    },
    phone:(alarm,event)async{
      if(!_pilotWakeOn||pilotWake.acknowledged)return;
      final l=lookupAppLocalizations(const Locale('en'));
      await NotificationCenter.instance.emit(NotificationEvent(dedupeKey:event.substring(0,event.lastIndexOf(':')),category:NotifCategory.reminders,priority:NotifPriority.critical,title:alarm.label,body:l.pilotAwakeExplanation,date:todayLabel(),route:kRouteAlarm),phoneOnly:true);
      if(alarm.phoneSound)await SystemSound.play(SystemSoundType.alert);
      if(alarm.phoneVibration)await vibratePhoneFor(const Duration(milliseconds:700));
    },
  );

  Future<void> _pilotSnoozeStarted(SnoozeState state)async{
    final alarm=_pilotFiredAlarm??pilotWake.firedAlarm,fire=state.fireAt;
    pilotWake.suspendFlash();
    if(!_pilotWakeOn||alarm==null||alarm.band||fire==null)return;
    await pilot.PilotSnoozeSlot.save(id:alarm.id,fire:fire,end:state.reAlarmAt);
    final result=await _armNextAlarmOccurrence();
    if(result.failed)throw StateError('Snooze backup did not reach the band');
  }
  Future<void> _clearPilotSnoozeSlot()async{
    final fire=pilotWake.firedAt,alarm=_pilotFiredAlarm??pilotWake.firedAlarm;if(fire==null||alarm==null)return;
    final slot=await pilot.PilotSnoozeSlot.load();
    if(slot==null||slot['id']!=alarm.id||(slot['fire'] as int)>fire.millisecondsSinceEpoch~/1000)return;
    await pilot.PilotSnoozeSlot.clear(fireEpoch:slot['fire'] as int);
    await _armNextAlarmOccurrence();
  }
  Future<bool> _playPilotPhoneSnooze()async{
    final alarm=_pilotFiredAlarm??pilotWake.firedAlarm;if(alarm==null)return false;
    final sent=await _deliverPilotApp(alarm,_wakeNow());
    if(sent){await _clearPilotSnoozeSlot();pilotWake.noteSnoozeFire(alarm,_wakeNow());}
    return sent;
  }
  Future<bool> _deliverPilotApp(pilot.PilotAlarm alarm,DateTime at)async{
      final sent=debugPilotAppFire!=null?await debugPilotAppFire!.call(alarm,at):await NotificationCenter.instance.emit(
        NotificationEvent(dedupeKey:'pilot-app:${alarm.id}:${at.millisecondsSinceEpoch}',category:NotifCategory.reminders,priority:NotifPriority.critical,
          title:alarm.label,body:lookupAppLocalizations(const Locale('en')).pilotAwakeExplanation,date:todayLabel(),route:kRouteAlarm),phoneOnly:true);
      if(sent){_pilotFiredAlarm=alarm.copy();wake.noteWakeAwaitingAck(at.millisecondsSinceEpoch~/1000,WakePath.alarm);}
      return sent;
    }
}
