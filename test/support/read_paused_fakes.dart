// A repository that behaves like LocalRepositoryImpl does while an import has
// the database to itself (lib/sync/import_focus.dart): every read is COUNTED,
// and while ImportFocus.active is true a read throws ReadPaused('import')
// unless the engine published that method's model for that day in
// ImportFocus.days (today and yesterday only, by method name).
import 'package:flutter/material.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/journal_fields.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/data/read_paused.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/sync/import_focus.dart';

String get kPendingLine =>
    lookupAppLocalizations(const Locale('en')).importPausedTodayPending;
String get kSavingLine =>
    lookupAppLocalizations(const Locale('en')).importPausedSaving;

final String kToday = todayLabel();
final String kYesterday =
    dayLabelOf(DateTime.now().subtract(const Duration(days: 1)));
final String kDay2 = dayLabelOf(DateTime.now().subtract(const Duration(days: 2)));

/// The one sentence every paused screen shows where older data would be.
String get kPausedLine =>
    lookupAppLocalizations(const Locale('en')).importPausedOlderDays;

/// What the engine would publish for today / yesterday.
Map<String, Map<String, dynamic>> publishedDays() => {
      kToday: {
        'getToday': {
          'daily': {
            'readiness': {'value': 77, 'confidence': .8, 'tier': 'HIGH'},
            'resting_hr': {'value': 51, 'confidence': .8, 'tier': 'HIGH'},
            'strain': {'value': 6.0, 'confidence': .8, 'tier': 'ESTIMATE'},
            'steps': {'value': 1200, 'confidence': .8, 'tier': 'ESTIMATE'},
          },
          'sleep': {
            'duration_min': {'value': 431, 'confidence': .8, 'tier': 'HIGH'},
          },
          'status': {'today_day': kToday},
        },
        'getDayOverview': {'readiness': 77, 'resting_hr': 51},
      },
      kYesterday: {
        'getDayOverview': {'readiness': 61, 'resting_hr': 55},
      },
    };

void startFocus([Map<String, Map<String, dynamic>>? days]) {
  ImportFocus.days.value = days ?? publishedDays();
  ImportFocus.active.value = true;
}

void endFocus() {
  ImportFocus.days.value = const {};
  ImportFocus.active.value = false;
}

/// Register in setUp/tearDown: focus state is static.
void resetFocus() {
  ImportFocus.days.value = const {};
  ImportFocus.active.value = false;
}

class FocusRepo extends LocalRepository {
  /// Every read, as `method` or `method:day`, in call order (paused ones too).
  final List<String> reads = [];

  int count(String method, [String? day]) => reads
      .where((r) => day == null ? r.split(':').first == method : r == '$method:$day')
      .length;

  /// The published model, null when focus is off; throws while it is on and
  /// nothing was published for that method and day.
  /// Normal (focus off) readiness by day, overriding the defaults.
  final Map<String, int> overview = {};

  /// The signature `artifactSignature` answers (null: none).
  String? sig;

  /// Called with the method name before the focus check (a test can start
  /// focus "between the reads and the write").
  void Function(String method)? onRead;

  Map<String, dynamic>? _gate(String method, [String? day]) {
    reads.add(day == null ? method : '$method:$day');
    onRead?.call(method);
    if (!ImportFocus.active.value) return null;
    final served = ImportFocus.days.value[day ?? todayLabel()]?[method];
    if (served is Map<String, dynamic>) return served;
    throw const ReadPaused('import');
  }

  @override
  Future<Map<String, dynamic>> getToday() async =>
      _gate('getToday') ?? _today();

  @override
  Future<Map<String, dynamic>> getTodayStored() async =>
      _gate('getToday') ?? _today();

  /// What a normal (focus off) read of today answers; null: the default.
  Map<String, dynamic>? todayPayload;

  Map<String, dynamic> _today() => todayPayload ?? {
        'daily': {
          'readiness': {'value': 70, 'confidence': .8, 'tier': 'HIGH'},
          'resting_hr': {'value': 50, 'confidence': .8, 'tier': 'HIGH'},
          'strain': {'value': 5.0, 'confidence': .8, 'tier': 'ESTIMATE'},
          'steps': {'value': 1000, 'confidence': .8, 'tier': 'ESTIMATE'},
        },
        'sleep': {
          'duration_min': {'value': 400, 'confidence': .8, 'tier': 'HIGH'},
        },
        'status': {'today_day': kToday},
      };

  @override
  Future<Map<String, dynamic>> getProfile() async => const {'name': 'Alex'};

  @override
  Future<Map<String, dynamic>> getInsights() async =>
      _gate('getInsights') ?? const {};

  @override
  Future<List<String>> availableDays() async {
    _gate('availableDays');
    return [kToday, kYesterday, kDay2];
  }

  @override
  Future<Map<String, dynamic>> getDayOverview(String date) async =>
      _gate('getDayOverview', date) ??
      {'readiness': overview[date] ?? (date == kYesterday ? 42 : 33), 'resting_hr': 60};

  @override
  Future<Map<String, dynamic>> getDayStrain(String date) async =>
      _gate('getDayStrain', date) ??
      {'strain': 9.9, 'steps': 2500, 'calories': 300, 'calories_total': 2000};

  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) async =>
      _gate('getDaySleepV2', date) ?? {'has_sleep': true, 'duration_min': 250};

  @override
  Future<SleepDetailBundle> getSleepDetailBundle(
    String day, {
    required List<String> chartKeys,
    required int windowDays,
    String? before,
  }) async {
    _gate('getSleepDetailBundle', day);
    return SleepDetailBundle(
      night: {'has_sleep': true, 'duration_min': 250},
      timeline: const {},
      insights: const {},
      charts: const {},
      windows: const [],
    );
  }

  @override
  Future<WearableDay?> wearableDay(String date) async {
    _gate('wearableDay', date);
    return null;
  }

  @override
  Future<int> pendingActivityCount() async {
    _gate('pendingActivityCount');
    return 0;
  }

  @override
  Future<List<Map<String, Object?>>> getDeviceNights(String date) async {
    _gate('getDeviceNights', date);
    return const [];
  }

  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) async =>
      _gate('getJournalInsights') ?? const {};

  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async =>
      _gate('getDayHeart', date) ?? const {};

  @override
  Future<Map<String, dynamic>> getDayHrv(String date) async =>
      _gate('getDayHrv', date) ?? const {};

  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async =>
      _gate('getDayNaps', date) ?? {'naps': <Map<String, dynamic>>[], 'nap_min': 0};

  @override
  Future<String?> artifactSignature(String key) async {
    reads.add('artifactSignature:$key');
    return sig;
  }

  @override
  Future<Map<String, int>> getSeriesCounts(List<String> keys) async {
    _gate('getSeriesCounts');
    return {for (final k in keys) k: 0};
  }

  /// 40 days of a flat series, newest last, ending today.
  @override
  Future<Map<String, dynamic>> getChart(String metric,
      {int? from, int? to, Set<String> signals = const {}}) async {
    _gate('getChart');
    final now = DateTime.now();
    return {
      'points': [
        for (var i = 39; i >= 0; i--)
          {
            't': DateTime(now.year, now.month, now.day - i, 12)
                    .millisecondsSinceEpoch ~/
                1000,
            'v': 50.0 + i % 5,
          },
      ],
    };
  }
}

/// Every read a "second batch" screen makes throws ReadPaused, whatever it
/// asks for (the screens here read things no import publishes).
class PausedRepo extends LocalRepository {
  final List<String> reads = [];
  Never _p(String m) {
    reads.add(m);
    throw const ReadPaused('import');
  }

  @override
  Future<List<String>> availableDays() async => _p('availableDays');
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) async => _p('getDayNaps');
  @override
  Future<Map<String, dynamic>> getToday() async => _p('getToday');
  @override
  Future<Map<String, dynamic>> getTodayStored() async => _p('getTodayStored');
  @override
  Future<Map<String, dynamic>> getInsights() async => _p('getInsights');
  @override
  Future<Map<String, dynamic>> getDayStress(String date) async => _p('getDayStress');
  @override
  Future<Map<String, dynamic>> getDayHeart(String date) async => _p('getDayHeart');
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async => _p('getDaySleep');
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) async =>
      _p('getChart');
  @override
  Future<List<Map<String, dynamic>>> getSessions(
          {int? from, int? to, bool includeDetected = true}) async =>
      _p('getSessions');
  @override
  Future<List<JournalFieldSpec>> getJournalFields() async => _p('getJournalFields');
  @override
  Future<Map<String, JournalMetricValue>> getJournalMetrics(String date) async =>
      _p('getJournalMetrics');
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) async =>
      _p('getJournal');
}
