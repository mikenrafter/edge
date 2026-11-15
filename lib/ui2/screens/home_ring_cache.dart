part of 'home_screen.dart';

// Owner: HomeRingDetailCache keeps bounded presentation snapshots. These are
// secondary, day-specific copies: never a source for ring scores or analytics.
class HomeRingDetailCache {
  HomeRingDetailCache({String Function()? userKey, this.limit = 32})
    : userKey =
          userKey ??
          (() => Prefs.getString('install_device_id', 'local-profile'));
  static final local = HomeRingDetailCache();
  static const prefKey = 'ui.home_ring_details.v1';
  final String Function() userKey;
  final int limit;
  final _entries = <String, dynamic>{};
  bool _restored = false, _saveScheduled = false;
  void _restore() {
    if (_restored || !Prefs.loaded) return;
    _restored = true;
    try {
      final decoded = jsonDecode(Prefs.getString(prefKey, '{}'));
      if (decoded is Map) {
        _entries.addAll(
          Map<String, dynamic>.fromEntries(
            decoded.entries
                .where((e) => e.key is String && e.value is Map)
                .take(limit)
                .map((e) => MapEntry(e.key as String, e.value)),
          ),
        );
      }
    } catch (_) {
      /* A damaged secondary cache loses only its presentation. */
    }
  }

  String _key(String day, String locale) => '${userKey()}:$day:$locale';
  ({HomeData data, String? help})? read(String day, String locale) {
    _restore();
    final raw = _entries[_key(day, locale)];
    if (raw is! Map) return null;
    try {
      final m = Map<String, dynamic>.from(raw);
      final stages = m['stages'] as Map?;
      final schedule = m['schedule'] as Map?;
      return (
        data: HomeData(
          dayId: day,
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
      );
    } catch (_) {
      return null;
    }
  }

  void record(String day, String locale, HomeData d, RingHelp? help) {
    _restore();
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
    final key = _key(day, locale);
    if (jsonEncode(_entries[key]) == jsonEncode(value)) return;
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first);
    }
    if (_saveScheduled) return;
    _saveScheduled = true;
    scheduleMicrotask(() async {
      _saveScheduled = false;
      try {
        final encoded = jsonEncode(_entries);
        await SettingsRepository.instance.update(
          (d) => d.setString(prefKey, encoded),
          sections: const {},
        );
      } catch (_) {
        /* Fresh stored reads remain authoritative if persistence fails. */
      }
    });
  }
}
