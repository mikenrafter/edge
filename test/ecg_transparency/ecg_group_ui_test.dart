// Design 04 phase 1 (RED) - items 2 and 5 on the DETAIL screen (no database):
//   * deleting from ANY attempt deletes the WHOLE group, and the confirm dialog
//     says so: "Delete this reading and all N attempts?" (N = rows in the
//     group), N = 1 -> "Delete this reading?" (R2''');
//   * the per-reading export goes through logFileName + the injected
//     LogResultSaver; a failure shows "Couldn't save the ECG log: <reason>";
//     no clipboard (AGENTS 3.16).
// The history list and "Export ECG logs" over a real LocalDb are in
// ecg_home_ui_test.dart (kept apart: the pre-change delete path touches the
// real LocalDb inside a fake-async test).
//
// ASSUMED keys: `ecg-export-reading` (detail). File names
// `openstrap-ecg...-log-<stamp>.txt` - only the "openstrap-ecg" prefix and the
// injected-clock stamp are asserted.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart'
    show kAlgoVersion, kAnalyticsPin, kProtocolPin;
import 'package:openstrap_edge/ecg/ecg_export.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';
import 'package:openstrap_edge/ecg/ecg_outcome.dart';
import 'package:openstrap_edge/l10n/app_localizations.dart';
import 'package:openstrap_edge/ui2/screens/ecg.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/util/log_file.dart';

import 'support/cardio_fixtures.dart';

final _now = DateTime.utc(2026, 10, 8, 12, 0, 0);
final _env = EcgExportEnv(appVersion: () async => '9.9.9+99', now: () => _now);

String _stamp() =>
    logFileName('k', _now).split('-log-').last.replaceAll('.txt', '');

Future<void> _pumpDetail(WidgetTester t, Widget w) async {
  t.view.physicalSize = const Size(1170, 12000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: w,
  ));
  await t.pump();
}

EcgReading _chain(String id, int attempt) => cardioReading(
  id: id,
  startTs: kC0 + attempt * 200,
  attemptGroup: 'A',
  attempt: attempt,
  supersededBy: attempt < 3 ? ['B', 'C'][attempt - 1] : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboard = <String>[];

  setUp(() async {
    clipboard.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboard.add(call.method);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  group('delete = the whole group, and the dialog says how many', () {
    EcgDetailData data3() => EcgDetailData(
      reading: _chain('C', 3),
      packets: const [],
      attempts: [_chain('A', 1), _chain('B', 2), _chain('C', 3)],
    );

    testWidgets('N = 3: "Delete this reading and all 3 attempts?"; confirming '
        'deletes once, with the id of the reading it was opened on', (t) async {
      final deleted = <String>[];
      await _pumpDetail(
        t,
        EcgDetailScreen(data: data3(), onDelete: (id) async => deleted.add(id)),
      );
      await t.tap(find.text('Delete reading'));
      await t.pumpAndSettle();
      expect(find.text('Delete this reading and all 3 attempts?'), findsOneWidget);
      expect(deleted, isEmpty, reason: 'nothing is deleted before the confirm');
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(deleted, ['C']);
    });

    testWidgets('Cancel deletes nothing', (t) async {
      final deleted = <String>[];
      await _pumpDetail(
        t,
        EcgDetailScreen(data: data3(), onDelete: (id) async => deleted.add(id)),
      );
      await t.tap(find.text('Delete reading'));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(deleted, isEmpty);
      expect(find.text('Delete this reading and all 3 attempts?'), findsNothing);
    });

    testWidgets('from an EARLIER attempt the dialog still counts the whole '
        'group', (t) async {
      final deleted = <String>[];
      await _pumpDetail(
        t,
        EcgDetailScreen(
          data: EcgDetailData(
            reading: _chain('A', 1),
            packets: const [],
            attempts: [_chain('A', 1), _chain('B', 2), _chain('C', 3)],
          ),
          onDelete: (id) async => deleted.add(id),
        ),
      );
      await t.tap(find.text('Delete reading'));
      await t.pumpAndSettle();
      expect(find.text('Delete this reading and all 3 attempts?'), findsOneWidget);
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(deleted, ['A']);
    });

    testWidgets('N = 1 (no attempts list, or a list of one): "Delete this '
        'reading?"', (t) async {
      for (final attempts in [const <EcgReading>[], [cardioReading(id: 'solo')]]) {
        await _pumpDetail(
          t,
          EcgDetailScreen(
            data: EcgDetailData(
              reading: cardioReading(id: 'solo'),
              packets: const [],
              attempts: attempts,
            ),
            onDelete: (id) async {},
          ),
        );
        await t.tap(find.text('Delete reading'));
        await t.pumpAndSettle();
        expect(find.text('Delete this reading?'), findsOneWidget);
        expect(find.textContaining('attempts?'), findsNothing);
        await t.tap(find.text('Cancel'));
        await t.pumpAndSettle();
      }
    });

    testWidgets('N = 2: "all 2 attempts"', (t) async {
      await _pumpDetail(
        t,
        EcgDetailScreen(
          data: EcgDetailData(
            reading: _chain('B', 2),
            packets: const [],
            attempts: [_chain('A', 1), _chain('B', 2)],
          ),
          onDelete: (id) async {},
        ),
      );
      await t.tap(find.text('Delete reading'));
      await t.pumpAndSettle();
      expect(find.text('Delete this reading and all 2 attempts?'), findsOneWidget);
    });
  });

  group('per-reading export (detail)', () {
    final a = _chain('A', 1), b = _chain('B', 2), c = _chain('C', 3);

    testWidgets('saves that reading\'s attempt group via the injected saver, '
        'with the same blocks the bulk export would print', (t) async {
      final source = FakeEcgSource([a, b, c], packets: {'B': [cardioPacket(1)]});
      final saved = <(String, String)>[];
      await _pumpDetail(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: c, packets: const [], attempts: [a, b, c]),
          exportSource: source,
          exportEnv: _env,
          saveLog: (name, text) async {
            saved.add((name, text));
            return const LogSaveOk();
          },
        ),
      );
      await t.tap(find.byKey(const ValueKey('ecg-export-reading')));
      await t.pumpAndSettle();
      expect(saved, hasLength(1));
      final (name, text) = saved.single;
      expect(name, matches(RegExp('^openstrap-ecg[a-z-]*-log-${_stamp()}\\.txt\$')));
      final header = EcgExportHeader(
        appVersion: '9.9.9+99',
        analyticsPin: kAnalyticsPin,
        protocolPin: kProtocolPin,
        algoVersion: kAlgoVersion,
        outcomeTableVersion: kEcgOutcomeTableVersion,
        exportedAt: _now,
      );
      expect(text, await buildEcgLogFor(header: header, source: source, readingId: 'C'),
          reason: 'one formatter for per-reading and bulk');
    });

    testWidgets('a failed export is visible', (t) async {
      await _pumpDetail(
        t,
        EcgDetailScreen(
          data: EcgDetailData(reading: c, packets: const [], attempts: [a, b, c]),
          exportSource: FakeEcgSource([a, b, c]),
          exportEnv: _env,
          saveLog: (name, text) async => const LogSaveFailed('no share target'),
        ),
      );
      await t.tap(find.byKey(const ValueKey('ecg-export-reading')));
      await t.pumpAndSettle();
      expect(find.text("Couldn't save the ECG log: no share target"), findsOneWidget);
      expect(clipboard, isEmpty);
    });
  });
}
