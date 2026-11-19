// Owner: PilotAlarmStore owns isolated pilot alarms. Drafts never write on change.
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import '../state/alarm_schedule.dart';
import 'pilot_flags.dart';

enum PilotAlarmType { sleep, workout }
enum GradualPattern { ramp, steady, wave }
enum SnoozeChaos { steady, little, lot, wild }

class PilotAlarm {
  PilotAlarm({required this.id, required this.label, this.type = PilotAlarmType.sleep,
    this.enabled = true, this.primary = false, Set<int>? days,
    this.wakeMinute = 420, this.earlyMinutes = 0, this.gradualMinutes = 15,
    this.gradual = false, this.pattern = GradualPattern.ramp,
    this.band = true, this.customPatternId, this.sunrise = false,
    this.phoneSound = false, this.phoneVibration = false, this.phoneFlash = false, this.flashDelayMinutes = 8, this.phoneDelayMinutes = 1,
    this.soundDelayMinutes=1,this.vibrationDelayMinutes=1,this.sunriseMinutes=30,
    this.snooze = true, this.snoozeMinutes = 9, this.maxSnoozes = 3,
    this.chaos = SnoozeChaos.little, this.workoutStartMinute = 1050,
    this.zone = 3, this.zoneMinutes = 5,this.referenceWakeMinute,this.onceEpochSec}) : days = days ?? {1,2,3,4,5};
  final String id;
  String label;
  PilotAlarmType type;
  bool enabled, primary, gradual, band, sunrise, phoneSound, phoneVibration, phoneFlash, snooze;
  Set<int> days;
  int wakeMinute, earlyMinutes, gradualMinutes, phoneDelayMinutes;
  int flashDelayMinutes,soundDelayMinutes,vibrationDelayMinutes,sunriseMinutes;
  int snoozeMinutes, maxSnoozes, workoutStartMinute, zone, zoneMinutes;
  GradualPattern pattern;
  SnoozeChaos chaos;
  String? customPatternId;
  int? referenceWakeMinute,onceEpochSec;
  PilotAlarm copy() => PilotAlarm.fromJson(toJson());
  int? gradualStart(int? expectedWakeMinute) => gradual ? (expectedWakeMinute??wakeMinute) - gradualMinutes : null;
  bool get canBePrimary => type == PilotAlarmType.sleep;
  Map<String, Object?> toJson() => {
    'onceEpochSec':onceEpochSec,'referenceWakeMinute':referenceWakeMinute,'id':id,'label':label,'type':type.name,'enabled':enabled,'primary':primary,
    'days':days.toList(),'wakeMinute':wakeMinute,'earlyMinutes':earlyMinutes,
    'gradualMinutes':gradualMinutes,'gradual':gradual,'pattern':pattern.name,
    'band':band,'customPatternId':customPatternId,'sunrise':sunrise,
    'phoneFlash':phoneFlash,'flashDelayMinutes':flashDelayMinutes,'phoneSound':phoneSound,'phoneVibration':phoneVibration,'phoneDelayMinutes':phoneDelayMinutes,
    'soundDelayMinutes':soundDelayMinutes,'vibrationDelayMinutes':vibrationDelayMinutes,'sunriseMinutes':sunriseMinutes,
    'snooze':snooze,'snoozeMinutes':snoozeMinutes,'maxSnoozes':maxSnoozes,
    'chaos':chaos.name,'workoutStartMinute':workoutStartMinute,'zone':zone,'zoneMinutes':zoneMinutes,
  };
  factory PilotAlarm.fromJson(Map<String,dynamic> j) => PilotAlarm(
    id:j['id'] as String,label:j['label'] as String,referenceWakeMinute:j['referenceWakeMinute'] as int?,onceEpochSec:j['onceEpochSec'] as int?,
    type:PilotAlarmType.values.byName(j['type'] as String),
    enabled:j['enabled'] as bool,primary:j['primary'] as bool,
    days:(j['days'] as List).cast<int>().toSet(),wakeMinute:j['wakeMinute'] as int,
    earlyMinutes:j['earlyMinutes'] as int,gradualMinutes:j['gradualMinutes'] as int,
    gradual:j['gradual'] as bool,pattern:GradualPattern.values.byName(j['pattern'] as String),
    band:j['band'] as bool,customPatternId:j['customPatternId'] as String?,sunrise:j['sunrise'] as bool,
    phoneFlash:j['phoneFlash'] as bool? ?? false,flashDelayMinutes:j['flashDelayMinutes'] as int? ?? 8,phoneSound:j['phoneSound'] as bool,phoneVibration:j['phoneVibration'] as bool,
    phoneDelayMinutes:j['phoneDelayMinutes'] as int,soundDelayMinutes:j['soundDelayMinutes'] as int? ?? 1,vibrationDelayMinutes:j['vibrationDelayMinutes'] as int? ?? 1,sunriseMinutes:j['sunriseMinutes'] as int? ?? 30,snooze:j['snooze'] as bool,
    snoozeMinutes:j['snoozeMinutes'] as int,maxSnoozes:j['maxSnoozes'] as int,
    chaos:SnoozeChaos.values.byName(j['chaos'] as String),
    workoutStartMinute:j['workoutStartMinute'] as int,zone:j['zone'] as int,zoneMinutes:j['zoneMinutes'] as int,
  );
}

class PilotAlarmStore {
  static const key = 'pilot.alarms.v1';
  static Future<List<PilotAlarm>> load() async {
    final json = (await SharedPreferences.getInstance()).getString(key);
    return json == null ? [] : [for(final j in jsonDecode(json) as List) PilotAlarm.fromJson((j as Map).cast<String,dynamic>())];
  }
  static Future<void> save(List<PilotAlarm> alarms,{DateTime? now}) async {
    final copies=[for(final a in alarms) a.copy()];
    final previous={for(final a in await load())a.id:a};
    final time=now??DateTime.now();
    for(final alarm in copies){
      if(alarm.enabled&&alarm.days.isEmpty&&(alarm.onceEpochSec==null||previous[alarm.id]?.enabled!=true||previous[alarm.id]?.wakeMinute!=alarm.wakeMinute)){
        var at=DateTime(time.year,time.month,time.day,alarm.wakeMinute~/60,alarm.wakeMinute%60);
        if(!at.isAfter(time))at=DateTime(time.year,time.month,time.day+1,alarm.wakeMinute~/60,alarm.wakeMinute%60);
        alarm.onceEpochSec=at.millisecondsSinceEpoch~/1000;
      }
    }
    final primaryDays=<int>{};
    for(final a in copies.reversed) {
      if(!a.canBePrimary) a.primary=false;
      if(a.primary) {
        if(a.days.any(primaryDays.contains)) a.primary=false;
        else primaryDays.addAll(a.days);
      }
      if((a.type==PilotAlarmType.sleep&&!a.band&&!a.phoneSound&&!a.phoneVibration&&!a.phoneFlash) || a.wakeMinute<0 || a.wakeMinute>=1440 || a.earlyMinutes<0 || a.earlyMinutes>720 ||
          a.gradualMinutes<0 || a.gradualMinutes>180 || a.snoozeMinutes<1 ||
          a.maxSnoozes<0 || (a.flashDelayMinutes<0||a.flashDelayMinutes>30||a.soundDelayMinutes<0||a.soundDelayMinutes>30||a.vibrationDelayMinutes<0||a.vibrationDelayMinutes>30||a.sunriseMinutes<5||a.sunriseMinutes>60) || a.days.any((d)=>d<1||d>7)) {
        throw const FormatException('Invalid alarm settings');
      }
    }
    if(!await (await SharedPreferences.getInstance()).setString(key,jsonEncode([for(final a in copies) a.toJson()]))) {
      throw StateError('Alarms were not saved');
    }
  }
}

List<AlarmScheduleEntry> _alarmEntries(PilotAlarm a,{required bool wakeMethods}){
  if(!a.enabled)return [];
  if(a.days.isEmpty){
    final epoch=a.onceEpochSec;if(epoch==null)return [];
    final at=DateTime.fromMillisecondsSinceEpoch(epoch*1000);
    return [AlarmScheduleEntry(weekday:at.weekday-1,hour:at.hour,minute:at.minute,oneShotAt:at,
      naturalWindowMinutes:wakeMethods&&a.type==PilotAlarmType.sleep?a.earlyMinutes:0)];
  }
  return [for(final d in a.days)AlarmScheduleEntry(weekday:d-1,hour:a.wakeMinute~/60,minute:a.wakeMinute%60,
    naturalWindowMinutes:wakeMethods&&a.type==PilotAlarmType.sleep?a.earlyMinutes:0)];
}
List<AlarmScheduleEntry> pilotAlarmSchedule(List<PilotAlarm> alarms,{required bool wakeMethods,Map<String,int> cancelledBackups=const {}})=>[
  for(final a in alarms)if(a.type==PilotAlarmType.sleep||wakeMethods)
    for(final entry in _alarmEntries(a,wakeMethods:wakeMethods))
      _nativeEntry(a,entry,wakeMethods,cancelledBackups[a.id]),
];
AlarmScheduleEntry _nativeEntry(PilotAlarm a,AlarmScheduleEntry entry,bool methods,int? cancelled){
  final offset=methods&&a.type==PilotAlarmType.sleep&&!a.band?1:0;
  final once=entry.oneShotAt?.add(Duration(minutes:offset));
  final minute=entry.hour*60+entry.minute+offset;
  return AlarmScheduleEntry(weekday:(entry.weekday+minute~/1440)%7,hour:(minute%1440)~/60,minute:minute%60,
    oneShotAt:once,nativeOffsetMinutes:offset,skippedAt:offset>0&&cancelled!=null?DateTime.fromMillisecondsSinceEpoch(cancelled*1000):null,
    naturalWindowMinutes:entry.naturalWindowMinutes);
}
// CLAIM(pilot-one-alarm-source): an enabled pilot sleep alarm selects the pilot
// store exclusively; until then the weekly wake remains in force.
// [alarm_screen_test: flag on selects one store and arms 06:30 once].
Future<List<AlarmScheduleEntry>> selectedAlarmSchedule(Future<List<AlarmScheduleEntry>> Function() production,{DateTime? at}) async {
  final prefs=await SharedPreferences.getInstance();
  await prefs.reload();
  if(prefs.getBool(PilotFlag.alarmScreen.key)!=true) return production();
  final alarms=await PilotAlarmStore.load();
  if(!alarms.any((a)=>a.enabled&&a.type==PilotAlarmType.sleep))return production();
  final now=at??DateTime.now();
  if(prefs.getBool(PilotFlag.wakeMethods.key)==true){
    final slot=await PilotSnoozeSlot.load();
    if(slot!=null){final at=DateTime.fromMillisecondsSinceEpoch((slot['native'] as int)*1000);
      if(at.isAfter(now))return [AlarmScheduleEntry(weekday:at.weekday-1,hour:at.hour,minute:at.minute,oneShotAt:at,nativeOffsetMinutes:1)];}
  }
  for(final alarm in alarms){
    final completed=prefs.getInt('pilot.workout.completed.${alarm.id}');
    if(completed==null)continue;
    final end=DateTime.fromMillisecondsSinceEpoch(completed*1000);
    if(end.isAfter(now)){if(alarm.onceEpochSec==completed)alarm.enabled=false;else alarm.days.remove(end.weekday);}
  }
  return pilotAlarmSchedule(alarms,wakeMethods:prefs.getBool(PilotFlag.wakeMethods.key)==true,
    cancelledBackups:{for(final a in alarms)if(prefs.getInt('pilot.backup.cancelled.${a.id}') case final int epoch)a.id:epoch});
}

String bandPatternFor(PilotAlarm alarm, {required bool connected}) => connected ? alarm.customPatternId ?? 'default' : 'default';
int chaosSpreadMilliseconds(SnoozeChaos chaos,int snoozeNumber)=>
  ((switch(chaos){SnoozeChaos.steady=>0,SnoozeChaos.little=>100,SnoozeChaos.lot=>300,SnoozeChaos.wild=>600})*snoozeNumber.clamp(0,10)).clamp(0,1500);

DateTime? pilotNextAt(PilotAlarm alarm,DateTime now) => nextAlarmOccurrence(_alarmEntries(alarm,wakeMethods:true),now);
DateTime? pilotPreviousAt(PilotAlarm alarm,DateTime now){
  if(!alarm.enabled)return null;
  if(alarm.days.isEmpty){final epoch=alarm.onceEpochSec;if(epoch==null)return null;final at=DateTime.fromMillisecondsSinceEpoch(epoch*1000);return at.isAfter(now)?null:at;}
  DateTime? latest;
  for(final day in alarm.days){
    var back=(now.weekday-day)%7;
    var at=DateTime(now.year,now.month,now.day-back,alarm.wakeMinute~/60,alarm.wakeMinute%60);
    if(at.isAfter(now)){back+=7;at=DateTime(now.year,now.month,now.day-back,alarm.wakeMinute~/60,alarm.wakeMinute%60);}
    if(latest==null||at.isAfter(latest))latest=at;
  }
  return latest;
}
DateTime workoutWindowStart(PilotAlarm alarm, DateTime end) {
  final start=DateTime(end.year,end.month,end.day,alarm.workoutStartMinute~/60,alarm.workoutStartMinute%60);
  return start.isBefore(end)?start:DateTime(end.year,end.month,end.day-1,alarm.workoutStartMinute~/60,alarm.workoutStartMinute%60);
}
int? usualMinute(List<int> minutes) {
  if(minutes.isEmpty) return null;
  // Center midnight-spanning samples before taking the median.
  final ordered=[for(final m in minutes) m<720?m+1440:m]..sort();
  return ordered[ordered.length~/2]%1440;
}
List<int> gradualOffsets(GradualPattern pattern) => switch(pattern) {
  GradualPattern.ramp=>[0,1200,2100,2700],
  GradualPattern.steady=>[0,700,1400,2100],
  GradualPattern.wave=>[0,500,1500,2000,3000],
};
List<int> snoozeOffsets(SnoozeChaos chaos,int number,math.Random random) {
  final spread=chaosSpreadMilliseconds(chaos,number);
  var at=0;
  return [0,for(var i=0;i<5;i++) at+=500+(spread==0?0:random.nextInt(spread+1))];
}

abstract interface class WorkoutAlarmPort {
  Future<void> arm(DateTime end);
  Future<void> cancel(DateTime end);
}
class WorkoutFailSafe {
  WorkoutFailSafe(this.port);
  final WorkoutAlarmPort port;
  DateTime? _start,_end;
  bool _cancelled=false;
  Future<void> prepare(DateTime start, DateTime end, {required bool previousAcknowledged}) async {
    if(!end.isAfter(start)) throw ArgumentError('Workout window must end after it starts');
    _start=start; _end=end; _cancelled=false;
    // Previous ALARM_SET / I'm up are not prerequisites for the native backstop.
    await port.arm(end);
  }
  Future<void> workout({required DateTime started, required int zone, required int minutes,
    required PilotAlarm alarm}) async {
    final start=_start,end=_end;
    if(start==null || end==null || _cancelled || started.isBefore(start) || !started.isBefore(end) ||
        zone<alarm.zone || minutes<alarm.zoneMinutes) return;
    await port.cancel(end);
    _cancelled=true;
  }
}

// One pending Band-off snooze owns the single native slot. The durable override
// is also read by headless sync; process death cannot restore the old Latest.
class PilotSnoozeSlot {
  static const key='pilot.native_snooze.v1';
  static Future<void> _tail=Future.value();
  static Future<void> _mutate(Future<void> Function(SharedPreferences) action){
    final result=_tail.then((_)async=>action(await SharedPreferences.getInstance()));
    _tail=result.catchError((Object _){});return result;
  }
  static Future<Map<String,dynamic>?> load()async{
    final raw=(await SharedPreferences.getInstance()).getString(key);
    return raw==null?null:(jsonDecode(raw) as Map).cast<String,dynamic>();
  }
  // Throws if the platform did not acknowledge persistence.
  static Future<void> save({required String id,required DateTime fire,required DateTime end})=>_mutate((prefs)async{
    if(!await prefs.setString(key,jsonEncode({'id':id,'fire':fire.millisecondsSinceEpoch~/1000,'end':end.millisecondsSinceEpoch~/1000,'native':end.add(const Duration(minutes:1)).millisecondsSinceEpoch~/1000})))throw StateError('Snooze backup was not saved');
  });
  static Future<void> clear({int? fireEpoch})=>_mutate((prefs)async{
    final raw=prefs.getString(key);if(raw==null)return;
    if(fireEpoch!=null&&(jsonDecode(raw) as Map)['fire']!=fireEpoch)return;
    if(!await prefs.remove(key))throw StateError('Snooze backup was not cleared');
  });
}
