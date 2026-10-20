// AppState.deriveProgress: a pass that is NOT a user sync (the scheduler's
// job, e.g. the re-derive after a backup import) reports each finished day,
// and the notifier is null whenever no pass runs.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/compute/derive_scheduler.dart';
import 'package:openstrap_edge/state/app_state.dart';

import 'support/app_state_derive_harness.dart';

const _db = 'openstrap_derive_progress_test.db';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => deriveDbSetUp(_db));
  tearDownAll(() => deriveDbTearDown(_db));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  AppState make() {
    final a = AppState.forTesting();
    addTearDown(a.dispose);
    a.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
    return a;
  }

  test('a scheduled pass reports every finished day, then clears', () async {
    final app = make();
    expect(app.deriveProgress.value, isNull, reason: 'no pass yet');
    final seen = <String>[];
    app.deriveProgress.addListener(() {
      final v = app.deriveProgress.value;
      seen.add(v == null
          ? 'null'
          : '${v.dayIndex}/${v.dayTotal} ${v.day} waiting=${v.waiting}');
    });
    const days = ['2026-09-19', '2026-09-20', '2026-09-21'];
    final during = <Object?>[];
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(days.length);
      onScopeDays?.call(days);
      for (var i = 0; i < days.length; i++) {
        onDayDone?.call(days[i], i + 1, days.length);
        await Future<void>.delayed(Duration.zero);
        final v = app.deriveProgress.value;
        during.add(v == null ? null : (v.dayIndex, v.dayTotal, v.day));
      }
      return days.length;
    };

    await app.debugRunScheduled(kind: DeriveJobKind.heavy);
    await until(() => app.deriveProgress.value == null,
        what: 'deriveProgress back to null');

    expect(during, [
      (1, 3, '2026-09-19'),
      (2, 3, '2026-09-20'),
      (3, 3, '2026-09-21'),
    ]);
    for (final d in days) {
      expect(seen.any((s) => s.contains(d)), isTrue, reason: '$d reported');
    }
    expect(seen.last, 'null');
    expect(seen.where((s) => s.contains('waiting=true')), isEmpty);
  });

  test('a pass that throws still clears the progress', () async {
    final app = make();
    app.debugDeriveRun = ({
      required heavy,
      required changedOnly,
      onScope,
      onScopeDays,
      onDayDone,
      onCrossDay,
    }) async {
      onScope?.call(2);
      onDayDone?.call('2026-09-20', 1, 2);
      throw StateError('derive failed');
    };

    await app.debugRunScheduled(kind: DeriveJobKind.heavy);
    await until(() => app.deriveProgress.value == null,
        what: 'deriveProgress back to null after a failed pass');
  });
}
