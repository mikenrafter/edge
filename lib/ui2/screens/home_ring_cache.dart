part of 'home_screen.dart';

// Owner: HomeRingDetailCache keeps bounded presentation snapshots. These are
// secondary, day-specific copies: never a source for ring scores or analytics.
class HomeRingDetailCache {
  HomeRingDetailCache({String Function()? userKey, int limit = 32})
    : userKey =
          userKey ??
          (() => Prefs.getString('install_device_id', 'local-profile')),
      _store = HomeSnapshotStore(limit: limit);
  static final local = HomeRingDetailCache._local();
  HomeRingDetailCache._local()
    : userKey = (() => Prefs.getString('install_device_id', 'local-profile')),
      _store = HomeSnapshotStore.local;
  static const prefKey = HomeSnapshotStore.prefKey;
  final String Function() userKey;
  final HomeSnapshotStore _store;

  String _key(String day, String locale) => '${userKey()}:$day:$locale';
  ({HomeData data, String? help, DateTime? readAt})? read(
    String day,
    String locale,
  ) {
    final raw = _store.read(_key(day, locale));
    if (raw == null) return null;
    try {
      final m = Map<String, dynamic>.from(raw);
      final stages = m['stages'] as Map?;
      final schedule = m['schedule'] as Map?;
      return (
        data: HomeData(
          dayId: day,
          overnightAt: _time(m['overnightAt']),
          activityAt: _time(m['activityAt']),
          overnightDay: m['overnightDay'] as String?,
          activityDay: m['activityDay'] as String?,
          readiness: Metric.parse(m['readiness']),
          strain: Metric.parse(m['strain']),
          sleepMin: Metric.parse(m['sleep']),
          sleepNeedMin: Metric.parse(m['need']),
          bedtime: Metric.parse(m['bedtime']),
          strainTarget: m['target'] as Map<String, dynamic>?,
          recoveryState: m['recoveryState'] as String?,
          readinessUpdate: m['update'] as Map<String, dynamic>?,
          absentDiag: m['absent'] as Map<String, dynamic>?,
          illnessState: m['illnessState'] as String?,
          illnessDay: m['illnessDay'] as String?,
          illnessZ: (m['illnessZ'] as num?)?.toDouble(),
          learnedOnsetMin: m['onset'] as int?,
          learnedWakeMin: m['wake'] as int?,
          cycleLenMin: m['cycle'] as int?,
          nextAlarm: m['alarm'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(m['alarm'] as int),
          sleepSchedule: schedule == null
              ? null
              : ExpectedSleepSchedule.fromJson(
                  Map<String, Object?>.from(schedule),
                ),
          sleepStages: stages == null
              ? null
              : SleepStageMin(
                  deep: stages['deep'] as int?,
                  rem: stages['rem'] as int?,
                  light: stages['light'] as int?,
                  awake: stages['awake'] as int?,
                ),
        ),
        help: m['help'] as String?,
        readAt: _time(m['readAt']),
      );
    } catch (_) {
      return null;
    }
  }

  static DateTime? _time(Object? ms) =>
      ms is int ? DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true) : null;

  void record(
    String day,
    String locale,
    HomeData d,
    RingHelp? help, {
    DateTime? readAt,
  }) {
    Map<String, Object?> metric(Metric m) => {
      'value': m.value,
      'unit': m.unit,
      'confidence': m.confidence,
      'tier': m.tier.name,
      'label': m.label,
      'inputs_used': m.inputsUsed,
      'beta': m.beta,
      'note': m.note,
      'from_older_version': m.fromOlderVersion,
      'older_version_reason': m.olderVersionReason,
    };
    final value = <String, Object?>{
      'readAt': (readAt ?? pc.clock.now()).millisecondsSinceEpoch,
      'overnightAt': d.overnightAt?.millisecondsSinceEpoch,
      'activityAt': d.activityAt?.millisecondsSinceEpoch,
      'overnightDay': d.overnightDay,
      'activityDay': d.activityDay,
      'readiness': metric(d.readiness),
      'strain': metric(d.strain),
      'sleep': metric(d.sleepMin),
      'need': metric(d.sleepNeedMin),
      'bedtime': metric(d.bedtime),
      'target': d.strainTarget,
      'recoveryState': d.recoveryState,
      'update': d.readinessUpdate,
      'absent': d.absentDiag,
      'illnessState': d.illnessState,
      'illnessDay': d.illnessDay,
      'illnessZ': d.illnessZ,
      'onset': d.learnedOnsetMin,
      'wake': d.learnedWakeMin,
      'cycle': d.cycleLenMin,
      'alarm': d.nextAlarm?.millisecondsSinceEpoch,
      'schedule': d.sleepSchedule?.toJson(),
      'help': help?.text,
      'stages': d.sleepStages == null
          ? null
          : {
              'deep': d.sleepStages!.deep,
              'rem': d.sleepStages!.rem,
              'light': d.sleepStages!.light,
              'awake': d.sleepStages!.awake,
            },
    };
    _store.record(_key(day, locale), value);
  }
}
