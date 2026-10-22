// The sync line (StatusLine, on all four tabs) must show an import started
// from the WELCOME screen: runImport -> AppState.importNoopCsv / importWhoopCsvs.
//
// The seam is the real runImport on a real AppState. Every change to either
// notifier is captured as a PAIR (importProgress, deriveProgress), because the
// line ranks import above derive and only a pair says what the person sees.
// Each distinct pair is then mounted in a real StatusLine with BOTH notifiers
// populated, and the text on screen is what is asserted.
//
// Honesty (AGENTS 3.3): the NOOP importer streams, so it cannot know how many
// days it will derive; the line says "Calculating…" and never "day i of N" from
// a count of days written so far. The WHOOP importer stores vendor snapshots
// and recalculates nothing, so no "Calculating" appears for it; it reports a
// measured copy count instead.
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/ui2/onboarding/welcome.dart';
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/theme.dart';

import 'step2/support/p23_support.dart';
import 'support/app_state_derive_harness.dart';

const _name = 'one_phase_welcome_path.db';

typedef _Pair = (ImportProgress?, DeriveProgress?);

/// An AppState that only holds the pair a snapshot recorded.
class _Show extends AppState {
  _Show(ImportProgress? imp, DeriveProgress? der) : super.forTesting() {
    importProgress.value = imp;
    derive.value = der;
  }
  final derive = ValueNotifier<DeriveProgress?>(null);
  @override
  ValueListenable<DeriveProgress?> get deriveProgress => derive;
}

File _noop(Directory tmp) {
  // Three local days, so a count of "days written so far" would publish 1/1,
  // 2/2, 3/3 if it were passed off as a total.
  final t = DateTime.now();
  final rows = StringBuffer('unix_s,iso_utc,stream,hr_bpm,rr_ms\n');
  for (var d = 3; d >= 1; d--) {
    final base =
        DateTime(t.year, t.month, t.day - d, 8).millisecondsSinceEpoch ~/ 1000;
    for (var i = 0; i < 300; i++) {
      rows.writeln('${base + i},x,hr,${60 + i % 5},');
    }
  }
  return File(p.join(tmp.path, 'noop.csv'))..writeAsStringSync(rows.toString());
}

File _whoop(Directory tmp) {
  String row(int n) => '${p23Day(n)} 08:30:00';
  return File(p.join(tmp.path, 'physiological_cycles.csv'))
    ..writeAsStringSync(
      'Cycle start time,Wake onset,Recovery score %,Resting heart rate (bpm),'
      'Heart rate variability (ms),Day Strain,Energy burned (cal),'
      'Asleep duration (min)\n'
      '${row(1)},${row(1)},42,70,19,7.5,2400,300\n'
      '${row(2)},${row(2)},55,68,25,9.1,2600,420\n',
    );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Runs [body] on a fresh AppState and returns every (import, derive) pair
  /// seen, in order, plus the final pair.
  Future<({List<_Pair> seen, _Pair last, Object? error})> run(
    WidgetTester t,
    Future<void> Function(AppState app, Directory tmp) body,
  ) async {
    late List<_Pair> seen;
    late _Pair last;
    Object? error;
    await t.runAsync(() async {
      await deriveDbSetUp(_name);
      SharedPreferences.setMockInitialValues({});
      final tmp = Directory.systemTemp.createTempSync('one_phase_welcome_');
      final app = AppState.forTesting();
      app.debugRescanRecent = ({onScopeDays, onDayDone}) async => 0;
      seen = [];
      void note() => seen.add((app.importProgress.value, app.deriveProgress.value));
      app.importProgress.addListener(note);
      app.deriveProgress.addListener(note);
      try {
        await body(app, tmp);
      } catch (e) {
        error = e;
      }
      last = (app.importProgress.value, app.deriveProgress.value);
      app.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
      await deriveDbTearDown(_name);
    });
    return (seen: seen, last: last, error: error);
  }

  /// What the person reads on the sync line for [pair].
  Future<String> lineFor(WidgetTester t, _Pair pair) async {
    final app = _Show(pair.$1, pair.$2);
    await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
            body: StatusLine(todayId: '2026-10-22', now: DateTime(2026, 10, 22, 12))),
      ),
    ));
    final text = t
        .widget<Text>(find.descendant(
            of: find.byType(StatusLine), matching: find.byType(Text)))
        .data!;
    await t.pumpWidget(const SizedBox());
    app.dispose();
    return text;
  }

  bool running(ImportProgress? v) =>
      v != null && v is! ImportDone && v is! ImportFailed;

  testWidgets('welcome NOOP import: the line moves from Importing to '
      'Calculating while days derive, with no invented total', (t) async {
    final r = await run(t, (app, tmp) async {
      final out = await runImport(app, [_noop(tmp).path]);
      expect(out.nothingLanded, isFalse, reason: 'guard: the import worked');
    });
    expect(r.error, isNull);

    final lines = <String>[];
    for (final pair in {...r.seen}) {
      lines.add(await lineFor(t, pair));
    }
    expect(lines.where((s) => s.startsWith('Importing')), isNotEmpty,
        reason: 'the line says so while the file is opened: $lines');
    expect(lines.where((s) => s == 'Calculating…'), isNotEmpty,
        reason: 'once days derive the line says so, not "Importing · opening" '
            'for the whole run: $lines');
    // The pair that carries derive progress must not be hidden by an import.
    for (final pair in r.seen.where((s) => s.$2 != null)) {
      expect(running(pair.$1), isFalse,
          reason: 'import progress outranks and hides the calculation');
      expect(pair.$2!.dayTotal, isNull,
          reason: 'a streaming import cannot know its total; days written so '
              'far is not "N" (${pair.$2!.dayIndex}/${pair.$2!.dayTotal})');
    }
    expect(lines.where((s) => s.contains(' of ')), isEmpty,
        reason: 'no "day i of N" without a measured N: $lines');
    // Terminal: the line is back to idle.
    expect(running(r.last.$1), isFalse);
    expect(r.last.$2, isNull);
  });

  testWidgets('welcome WHOOP import: a measured copy count, and no '
      '"Calculating" for work that recalculates nothing', (t) async {
    final r = await run(t, (app, tmp) async {
      final out = await runImport(app, [_whoop(tmp).path]);
      expect(out.nothingLanded, isFalse, reason: 'guard: the import worked');
    });
    expect(r.error, isNull);

    final copying = r.seen
        .map((s) => s.$1)
        .whereType<ImportCopying>()
        .toList();
    expect(copying, isNotEmpty,
        reason: 'the real stage is published, not "opening" throughout');
    expect(copying.map((c) => c.rowsTotal).toSet(), {2},
        reason: 'two days in the file: the total is measured, not guessed');
    expect(copying.every((c) => c.rowsDone <= c.rowsTotal), isTrue);
    expect(copying.map((c) => c.rowsDone), contains(2));
    expect(r.seen.where((s) => s.$2 != null), isEmpty,
        reason: 'nothing is recalculated, so no calculation progress');
    final lines = [for (final pair in {...r.seen}) await lineFor(t, pair)];
    expect(lines.where((s) => s.startsWith('Importing')), isNotEmpty);
    expect(lines.where((s) => s.startsWith('Calculating')), isEmpty,
        reason: '$lines');
    expect(running(r.last.$1), isFalse);
    expect(r.last.$2, isNull);
  });

  testWidgets('a NOOP import that throws clears both notifiers', (t) async {
    final r = await run(t, (app, tmp) async {
      await app.importNoopCsv(p.join(tmp.path, 'missing.csv'));
    });
    expect(r.error, isNotNull, reason: 'guard: the import failed');
    expect(r.seen.map((s) => s.$1).where(running), isNotEmpty,
        reason: 'guard: it did publish before failing');
    expect(running(r.last.$1), isFalse, reason: 'stuck "Importing"');
    expect(r.last.$2, isNull, reason: 'stuck calculation');
  });

  testWidgets('a WHOOP import that throws clears both notifiers', (t) async {
    final r = await run(t, (app, tmp) async {
      final f = File(p.join(tmp.path, 'notes.csv'))..writeAsStringSync('a,b\n1,2\n');
      await app.importWhoopCsvs([f.path]);
    });
    expect(r.error, isNotNull, reason: 'guard: nothing recognised throws');
    expect(running(r.last.$1), isFalse, reason: 'stuck "Importing"');
    expect(r.last.$2, isNull);
  });

  // A backup's failure stays until the NEXT BACKUP starts (or it is dismissed).
  // A CSV import that began while it was retained must not bring it back after
  // a newer backup retired it.
  for (final kind in ['NOOP', 'WHOOP']) {
    testWidgets('$kind CSV finishing after a newer backup started does not '
        'resurrect the retired failure', (t) async {
      ImportFailed? first;
      final r = await run(t, (app, tmp) async {
        await expectLater(
            app.importEdgeBackup(p.join(tmp.path, 'missing-1.db')), throwsA(anything));
        first = app.importProgress.value as ImportFailed;
        expect(first, isNotNull, reason: 'guard: the failure is retained');

        // The newer backup starts while the CSV is mid-run (after its first
        // derived day / first copied day). Starting it retires the failure.
        Future<void>? newer;
        void startNewer() {
          if (newer != null) return;
          final live = kind == 'NOOP'
              ? app.deriveProgress.value != null
              : app.importProgress.value is ImportCopying;
          if (!live) return;
          newer = app
              .importEdgeBackup(p.join(tmp.path, 'missing-2.db'))
              .then<void>((_) {}, onError: (_) {});
        }

        app.deriveProgress.addListener(startNewer);
        app.importProgress.addListener(startNewer);
        if (kind == 'NOOP') {
          await app.importNoopCsv(_noop(tmp).path);
        } else {
          await app.importWhoopCsvs([_whoop(tmp).path]);
        }
        expect(newer, isNotNull, reason: 'guard: the overlap happened');
        await newer;
      });
      expect(r.error, isNull);
      expect(identical(r.last.$1, first), isFalse,
          reason: 'the CSV cleanup restored a failure a newer backup retired');
    });
  }
}
