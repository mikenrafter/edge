// Timing decorator over the real repository, for the heavy load measurements.
//
// Subclass of LocalRepositoryImpl: every read the measured screens make goes
// through `_t`, which records start/end (Stopwatch ms since `origin`), so the
// table answers "which call, how many times, how long". Times are inclusive
// of everything the call awaits (isolate hops included). Stopwatch is
// monotonic elapsed time, the accepted exception to the no-clock rule for
// these gated heavy tests.
import 'package:openstrap_edge/data/local_repository.dart' show SleepDetailBundle;
import 'package:openstrap_edge/data/local_repository_impl.dart';

class CallRecord {
  CallRecord(this.name, this.startMs, this.endMs);
  final String name;
  final int startMs;
  final int endMs;
  int get ms => endMs - startMs;
}

class CallLog {
  final Stopwatch clock = Stopwatch()..start();
  final List<CallRecord> records = [];

  void reset() {
    records.clear();
    clock
      ..reset()
      ..start();
  }

  /// Top [n] methods by total ms: name, count, total, max.
  String table({int n = 10}) {
    final by = <String, List<CallRecord>>{};
    for (final r in records) {
      by.putIfAbsent(r.name, () => []).add(r);
    }
    final rows = by.entries.toList()
      ..sort((a, b) => b.value.fold<int>(0, (s, r) => s + r.ms)
          .compareTo(a.value.fold<int>(0, (s, r) => s + r.ms)));
    final b = StringBuffer('  call | count | total ms | max ms\n');
    for (final e in rows.take(n)) {
      final total = e.value.fold<int>(0, (s, r) => s + r.ms);
      final max = e.value.fold<int>(0, (s, r) => r.ms > s ? r.ms : s);
      b.writeln('  ${e.key} | ${e.value.length} | $total | $max');
    }
    return b.toString();
  }

  /// First [n] calls in start order: the sequence the screen really made.
  String timeline({int n = 40}) {
    final l = [...records]..sort((a, b) => a.startMs.compareTo(b.startMs));
    final b = StringBuffer('  start..end ms | call\n');
    for (final r in l.take(n)) {
      b.writeln('  ${r.startMs}..${r.endMs} (${r.ms}) | ${r.name}');
    }
    return b.toString();
  }
}

class TimedRepository extends LocalRepositoryImpl {
  TimedRepository(this.log, {required super.getProfileMap});
  final CallLog log;

  Future<T> _t<T>(String name, Future<T> Function() f) async {
    final s = log.clock.elapsedMilliseconds;
    try {
      return await f();
    } finally {
      log.records.add(CallRecord(name, s, log.clock.elapsedMilliseconds));
    }
  }

  @override
  Future<Map<String, dynamic>> getProfile() =>
      _t('getProfile', () => super.getProfile());
  @override
  Future<Map<String, dynamic>> getToday() =>
      _t('getToday', () => super.getToday());
  @override
  Future<List<Map<String, dynamic>>> sleepWindows({int days = 60}) =>
      _t('sleepWindows', () => super.sleepWindows(days: days));
  @override
  Future<Map<String, dynamic>> getDayBlock(String day, List<String> keys) =>
      _t('getDayBlock', () => super.getDayBlock(day, keys));
  @override
  Future<List<Map<String, dynamic>>> getSessions(
          {int? from, int? to, bool includeDetected = true}) =>
      _t('getSessions',
          () => super.getSessions(from: from, to: to, includeDetected: includeDetected));
  @override
  Future<Map<String, dynamic>> getInsights() =>
      _t('getInsights', () => super.getInsights());
  @override
  Future<Map<String, dynamic>> getDaySleepV2(String date) =>
      _t('getDaySleepV2', () => super.getDaySleepV2(date));
  @override
  Future<Map<String, dynamic>> getDayStrain(String date) =>
      _t('getDayStrain', () => super.getDayStrain(date));
  @override
  Future<Map<String, dynamic>> getDayOverview(String date) =>
      _t('getDayOverview', () => super.getDayOverview(date));
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) =>
      _t('getDaySleep', () => super.getDaySleep(date));
  @override
  Future<Map<String, dynamic>> getDayTimeline(String date) =>
      _t('getDayTimeline', () => super.getDayTimeline(date));
  @override
  Future<Map<String, dynamic>> getDayStress(String date) =>
      _t('getDayStress', () => super.getDayStress(date));
  @override
  Future<Map<String, dynamic>> getDayHeart(String date) =>
      _t('getDayHeart', () => super.getDayHeart(date));
  @override
  Future<Map<String, dynamic>> getDayLungs(String date) =>
      _t('getDayLungs', () => super.getDayLungs(date));
  @override
  Future<Map<String, dynamic>> getDayWear(String date) =>
      _t('getDayWear', () => super.getDayWear(date));
  @override
  Future<Map<String, dynamic>> getDayNaps(String date) =>
      _t('getDayNaps', () => super.getDayNaps(date));
  @override
  Future<Map<String, dynamic>> getDayHrv(String date) =>
      _t('getDayHrv', () => super.getDayHrv(date));
  @override
  Future<Map<String, dynamic>> getDaySteps(String date) =>
      _t('getDaySteps', () => super.getDaySteps(date));
  @override
  Future<List<String>> availableDays() =>
      _t('availableDays', () => super.availableDays());
  @override
  Future<Map<String, dynamic>> getRecords() =>
      _t('getRecords', () => super.getRecords());
  @override
  Future<SleepDetailBundle> getSleepDetailBundle(String day,
          {required List<String> chartKeys, required int windowDays}) =>
      _t('getSleepDetailBundle',
          () => super.getSleepDetailBundle(day,
              chartKeys: chartKeys, windowDays: windowDays));
  @override
  Future<Map<String, dynamic>> getChart(String metric,
          {int? from, int? to, Set<String> signals = const {}}) =>
      _t('getChart($metric)',
          () => super.getChart(metric, from: from, to: to, signals: signals));
  @override
  Future<List<Map<String, dynamic>>> getJournal({String range = '30d'}) =>
      _t('getJournal', () => super.getJournal(range: range));
  @override
  Future<Map<String, dynamic>> getJournalInsights({String range = '90d'}) =>
      _t('getJournalInsights', () => super.getJournalInsights(range: range));
  @override
  Future<Map<String, dynamic>> getCycle() =>
      _t('getCycle', () => super.getCycle());
}
