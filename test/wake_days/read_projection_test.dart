import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/personal_day.dart';
import 'package:openstrap_edge/ui2/personal_day_inputs.dart';
import 'package:openstrap_edge/ui2/screens/home_screen.dart';
import 'package:openstrap_edge/ui2/screens/day_timeline.dart';
import '../backup/backup_support.dart';
import '../support/live_guide_harness.dart' show GuideFakeRepo;

class _Repo extends GuideFakeRepo {
  final readDates = <String>[];
  @override
  Future<List<String>> availableDays() async => ['2026-11-03', '2026-11-02'];
  @override
  Future<List<Map<String,dynamic>>> sleepWindows({int days = 60, String? before}) async => [
    {'date': '2026-11-02', 'onset_ts': DateTime(2026,11,1,23).millisecondsSinceEpoch~/1000,
      'wake_ts': DateTime(2026,11,2,8).millisecondsSinceEpoch~/1000},
    {'date': '2026-11-03', 'onset_ts': DateTime(2026,11,2,23).millisecondsSinceEpoch~/1000,
      'wake_ts': DateTime(2026,11,3,8).millisecondsSinceEpoch~/1000},
    // Keep the current cycle on Nov 4 so it does not reserve the historical
    // Nov 3 score this test reads with an explicit last choice (r3 S2).
    {'date': '2026-11-04', 'onset_ts': DateTime(2026,11,3,23).millisecondsSinceEpoch~/1000,
      'wake_ts': DateTime(2026,11,4,8).millisecondsSinceEpoch~/1000},
  ];
  @override
  Future<Map<String,dynamic>> getDayStrain(String date) async {
    readDates.add(date);
    return {'strain': date == '2026-11-02' ? 7 : 12};
  }
  @override
  Future<Map<String,dynamic>> getDayTimeline(String date) async => {
    'date': date, 'day_start': DateTime.parse(date).millisecondsSinceEpoch~/1000,
    'hr': [{'t': DateTime.parse(date).add(const Duration(hours: 9)).millisecondsSinceEpoch~/1000, 'v': 62}],
  };
}
void main() {
  late BackupEnv env;
  setUpAll(() async { env = await BackupEnv.create('wake_days.db'); await LocalDb.instance; });
  tearDownAll(() => env.dispose());
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.reload();
  });
  // WHY: new choices must not silently change existing users; invalid restored
  // values must abstain to the documented default. catches: enum.byName crash.
  test('absent and malformed settings keep the legacy default', () async {
    expect(Prefs.personalDayEnabled, isFalse);
    expect(Prefs.personalDayMode, PersonalDayMode.calendarOffset);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
    SharedPreferences.setMockInitialValues({'ui.personal_day_mode': 42, 'ui.personal_day_totals': ''});
    await Prefs.reload();
    expect(Prefs.personalDayEnabled, isFalse);
    expect(Prefs.personalDayMode, PersonalDayMode.calendarOffset);
    expect(Prefs.personalDayTotals, PersonalDayTotals.first);
  });
  // WHY: prove the production loaders call the boundary helper, not merely
  // that its unit tests pass. A calendar score must be read exactly once.
  test('Home and timeline share a cycle and one calendar score anchor', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    await Prefs.setPersonalDayTotals(PersonalDayTotals.last); // wake-to-wake's default is first
    final repo = _Repo();
    final at = DateTime(2026,11,4,12);
    await withClock(Clock.fixed(at), () async {
      final home = await HomeData.loadForDay(repo, '2026-11-02');
      final timeline = await TimelineData.load(repo, want: '2026-11-02', now: at);
      expect(home.personalDay!.start, DateTime(2026,11,2,8));
      expect(home.personalDay!.end, DateTime(2026,11,3,8));
      expect(timeline.personalView!.day.id, home.personalDay!.id);
      expect(home.strain.value, 12);
      expect(repo.readDates, ['2026-11-03']);
      expect(timeline.graph.slots, 1440);
      expect(timeline.graph.hr[60], 62);
    });
  });
  test('explicit calendar mode uses noon while unset preserves midnight', () async {
    final repo = _Repo();
    final at = DateTime(2026,11,4,12);
    final legacy = await TimelineData.load(repo, want: '2026-11-02', now: at);
    expect(legacy.personalView, isNull);
    expect(legacy.graph.dayStart, DateTime(2026,11,2).millisecondsSinceEpoch~/1000);
    await Prefs.setPersonalDayMode(PersonalDayMode.calendarOffset);
    expect(Prefs.personalDayEnabled, isTrue);
    final chosen = await TimelineData.load(repo, want: '2026-11-02', now: at);
    expect(chosen.personalView!.day.start, DateTime(2026,11,2,12));
    expect(chosen.personalView!.day.end, DateTime(2026,11,3,12));
  });
  test('persisted evidence counts but a buzz alone does not', () async {
    await Prefs.setPersonalDayMode(PersonalDayMode.wakeToWake);
    final onset = DateTime(2026,11,2,23).millisecondsSinceEpoch~/1000;
    final up = DateTime(2026,11,3,7).millisecondsSinceEpoch~/1000;
    await LocalDb.putWakeEvidence(onsetSec: onset, kind: 'naturalWake', atSec: up);
    final buzz = await readPersonalDay(_Repo(), '2026-11-03', now: DateTime(2026,11,3,7,30), current: true);
    expect(buzz!.awake, isFalse);
    await LocalDb.putWakeEvidence(onsetSec: onset, kind: 'alarmAcknowledged', atSec: up);
    final ack = await readPersonalDay(_Repo(), '2026-11-03', now: DateTime(2026,11,3,7,30), current: true);
    expect(ack!.awake, isTrue);
    expect(ack.day.start, DateTime(2026,11,3,7));
  });
}
