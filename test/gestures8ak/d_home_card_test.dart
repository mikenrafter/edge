// 8AK D (red): the Home card for a failed gesture.
//
// USER: "The next time Home is opened, show ONE card styled like the Join
// Discord card: 'An ECG gesture failed to activate' / 'A gesture failed to
// activate'; actions: 'Save log file' (a .txt through the platform save/share
// flow, NOT the clipboard), 'Report' (GitHub issues link + the community
// links, with one line encouraging a report), 'Dismiss'. The card text says
// that dismissed failures stay viewable in Settings. Only the newest
// undismissed failure shows; dismiss persists."
//
// ASSUMED API:
//   * NEW lib/ui2/gesture_failure_card.dart:
//       class GestureFailureCard extends StatefulWidget {
//         const GestureFailureCard({super.key, required GestureFailureStore
//             store, GestureLogSaver? saveLog, Future<bool> Function(String
//             url)? openLink});
//       }
//     It listens to [store] and draws the store's `newestUndismissed`, or
//     nothing (a zero-height box, no text) when there is none. Defaults:
//     `saveGestureLog` (gesture_log_file.dart) and `open3rdPartyLink`
//     (community_links.dart). The card is a `Surface` laid out like the
//     community nudge (a 32 pt tinted glyph, a bold title, a body line, a soft
//     `BigButton`), with a top gap of S.x5 like it.
//   * `typedef GestureLogSaver = Future<bool> Function(GestureFailure f)` in
//     lib/gestures/gesture_log_file.dart.
//   * Keys: card `gesture-failure-card`; actions `gesture-failure-save`
//     ("Save log file"), `gesture-failure-report` ("Report"),
//     `gesture-failure-dismiss` ("Dismiss").
//   * Titles: an ECG failure "An ECG gesture failed to activate", a
//     double-tap one "A gesture failed to activate". The body says dismissed
//     failures stay viewable in Settings (it names "Settings" and "Gesture
//     failures").
//   * Save calls the saver with the shown failure; the card stays (a saved log
//     is not a dismissal). A saver that returns false shows "Could not save
//     the log file." inside the card.
//   * Report opens a bottom sheet (key `gesture-report-sheet`) with ONE line
//     encouraging a report (key `gesture-report-encourage`) and three rows,
//     `gesture-report-github` (kGithubUrl + '/issues'),
//     `gesture-report-discord` (kDiscordUrl), `gesture-report-reddit`
//     (kRedditUrl); a row calls `openLink` with its URL. (The Settings list
//     reuses the same sheet.)
//   * Dismiss calls `store.dismiss(<shown id>)`; the card goes and, the next
//     failure aside, does not come back after a restart.
//   * lib/ui2/screens/home_screen.dart places `GestureFailureCard(...)` beside
//     `CommunityNudge()`, fed by `AppState.gestureFailures`.
//
// Failure mode today: the file does not exist (this file does not compile
// until it does).

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/gesture_failures.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import '../phase8/support/dart_source.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 4, 12, 7, 31);

class _Backing {
  String? raw;
  GestureFailureStore store() => GestureFailureStore(
        read: () => raw,
        write: (s) async => raw = s,
        now: () => _t0,
      );
}

Future<void> _record(GestureFailureStore s, String id,
        {GestureFailureKind kind = GestureFailureKind.ecg, int minute = 0}) async {
  await s.record(
    kind: kind,
    reason: kind == GestureFailureKind.ecg ? 'start_failed' : 'log_water',
    gestureId: id,
    log: 'log of $id',
    at: _t0.add(Duration(minutes: minute)),
  );
}

class _Rig {
  final saved = <String>[];
  final opened = <String>[];
  bool saveOk = true;

  Widget card(GestureFailureStore s, {double scale = 1}) => MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (c) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: GestureFailureCard(
                  store: s,
                  saveLog: (f) async {
                    saved.add(f.gestureId);
                    return saveOk;
                  },
                  openLink: (url) async {
                    opened.add(url);
                    return true;
                  },
                ),
              ),
            ),
          ),
        ),
      );
}

void _phone(WidgetTester t, {double width = 390}) {
  t.view.physicalSize = Size(width * 3, 800 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

const _cardKey = ValueKey('gesture-failure-card');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboardCalls = <String>[];

  setUp(() {
    clipboardCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method.startsWith('Clipboard.')) clipboardCalls.add(call.method);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  group('what shows', () {
    testWidgets('no failure: nothing at all', (t) async {
      _phone(t);
      await t.pumpWidget(_Rig().card(_Backing().store()));
      expect(find.byKey(_cardKey), findsNothing);
      expect(find.textContaining('failed to activate'), findsNothing);
    });

    testWidgets('an ECG failure: "An ECG gesture failed to activate"',
        (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(_Rig().card(s));
      expect(find.byKey(_cardKey), findsOneWidget);
      expect(find.text('An ECG gesture failed to activate'), findsOneWidget);
      expect(find.text('A gesture failed to activate'), findsNothing);
    });

    testWidgets('a double-tap failure: "A gesture failed to activate"',
        (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a', kind: GestureFailureKind.doubleTap);
      await t.pumpWidget(_Rig().card(s));
      expect(find.text('A gesture failed to activate'), findsOneWidget);
      expect(find.text('An ECG gesture failed to activate'), findsNothing);
    });

    testWidgets('three actions, by name: Save log file, Report, Dismiss',
        (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(_Rig().card(s));
      for (final e in const {
        'gesture-failure-save': 'Save log file',
        'gesture-failure-report': 'Report',
        'gesture-failure-dismiss': 'Dismiss',
      }.entries) {
        final f = find.byKey(ValueKey(e.key));
        expect(f, findsOneWidget, reason: e.key);
        expect(find.descendant(of: f, matching: find.text(e.value)),
            findsOneWidget,
            reason: e.key);
      }
    });

    testWidgets('the text says dismissed failures stay viewable in Settings',
        (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(_Rig().card(s));
      final body = find.descendant(
          of: find.byKey(_cardKey),
          matching: find.byWidgetPredicate((w) =>
              w is Text &&
              (w.data ?? '').contains('Settings') &&
              (w.data ?? '').contains('Gesture failures')));
      expect(body, findsOneWidget);
    });

    testWidgets('styled like the Join Discord card: inside a Surface, a 32 pt '
        'glyph tile, a bold title', (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(_Rig().card(s));
      final card = find.byKey(_cardKey);
      final title = find.text('An ECG gesture failed to activate');
      expect(find.ancestor(of: title, matching: find.byType(Surface)),
          findsWidgets);
      expect(t.widget<Text>(title).style?.fontWeight, FontWeight.w600);
      final tile = find
          .descendant(of: card, matching: find.byType(Container))
          .evaluate()
          .where((e) => (e.renderObject as RenderBox).size == const Size(32, 32));
      expect(tile, isNotEmpty, reason: 'the 32 pt glyph tile');
    });
  });

  group('one at a time, once per failure', () {
    testWidgets('only the newest undismissed failure shows, one card',
        (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'old', kind: GestureFailureKind.doubleTap);
      await _record(s, 'new', minute: 5);
      await t.pumpWidget(_Rig().card(s));
      expect(find.byKey(_cardKey), findsOneWidget);
      expect(find.text('An ECG gesture failed to activate'), findsOneWidget);
      expect(find.text('A gesture failed to activate'), findsNothing);
    });

    testWidgets('the same failure reported twice is one card', (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a');
      await s.record(
          kind: GestureFailureKind.ecg, reason: 'x', gestureId: 'a');
      await t.pumpWidget(_Rig().card(s));
      expect(find.byKey(_cardKey), findsOneWidget);
    });

    testWidgets('Dismiss removes the card; a later failure brings one back',
        (t) async {
      _phone(t);
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(_Rig().card(s));
      await t.tap(find.byKey(const ValueKey('gesture-failure-dismiss')));
      await t.pumpAndSettle();
      expect(find.byKey(_cardKey), findsNothing);
      expect(s.newestUndismissed, isNull);
      await _record(s, 'b', minute: 10);
      await t.pumpAndSettle();
      expect(find.byKey(_cardKey), findsOneWidget);
    });

    testWidgets('a dismissal survives a restart: no card for it after',
        (t) async {
      _phone(t);
      final b = _Backing();
      final s = b.store();
      await _record(s, 'a');
      await t.pumpWidget(_Rig().card(s));
      await t.tap(find.byKey(const ValueKey('gesture-failure-dismiss')));
      await t.pumpAndSettle();
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(_Rig().card(b.store())); // the app restarted
      expect(find.byKey(_cardKey), findsNothing);
    });

    testWidgets('an undismissed failure comes back after a restart',
        (t) async {
      _phone(t);
      final b = _Backing();
      await _record(b.store(), 'a');
      await t.pumpWidget(_Rig().card(b.store()));
      expect(find.byKey(_cardKey), findsOneWidget);
    });
  });

  group('Save log file', () {
    testWidgets('hands the shown failure to the saver; the card stays',
        (t) async {
      _phone(t);
      final r = _Rig();
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(r.card(s));
      await t.tap(find.byKey(const ValueKey('gesture-failure-save')));
      await t.pumpAndSettle();
      expect(r.saved, ['a']);
      expect(find.byKey(_cardKey), findsOneWidget);
      expect(s.newestUndismissed, isNotNull, reason: 'saving is not dismissing');
      expect(clipboardCalls, isEmpty, reason: 'never the clipboard');
    });

    testWidgets('a save that failed says so inside the card', (t) async {
      _phone(t);
      final r = _Rig()..saveOk = false;
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(r.card(s));
      await t.tap(find.byKey(const ValueKey('gesture-failure-save')));
      await t.pumpAndSettle();
      expect(
          find.descendant(
              of: find.byKey(_cardKey),
              matching: find.textContaining('Could not save')),
          findsOneWidget);
    });
  });

  group('Report', () {
    testWidgets('opens a sheet: one encouraging line and the GitHub issues, '
        'Discord and Reddit links', (t) async {
      _phone(t);
      final r = _Rig();
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(r.card(s));
      await t.tap(find.byKey(const ValueKey('gesture-failure-report')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('gesture-report-sheet')), findsOneWidget);
      final line = find.byKey(const ValueKey('gesture-report-encourage'));
      expect(line, findsOneWidget);
      expect(t.widget<Text>(line).data, isNotEmpty);
      for (final e in {
        'gesture-report-github': '$kGithubUrl/issues',
        'gesture-report-discord': kDiscordUrl,
        'gesture-report-reddit': kRedditUrl,
      }.entries) {
        await t.tap(find.byKey(ValueKey(e.key)));
        await t.pumpAndSettle();
        expect(r.opened.last, e.value, reason: e.key);
        if (find.byKey(const ValueKey('gesture-report-sheet')).evaluate().isEmpty) {
          // A row may close the sheet: open it again for the next one.
          await t.tap(find.byKey(const ValueKey('gesture-failure-report')));
          await t.pumpAndSettle();
        }
      }
      expect(r.opened, hasLength(3));
      expect(clipboardCalls, isEmpty);
    });

    testWidgets('reporting is not a dismissal', (t) async {
      _phone(t);
      final r = _Rig();
      final s = _Backing().store();
      await _record(s, 'a');
      await t.pumpWidget(r.card(s));
      await t.tap(find.byKey(const ValueKey('gesture-failure-report')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('gesture-report-github')));
      await t.pumpAndSettle();
      expect(s.newestUndismissed, isNotNull);
    });
  });

  group('fits a 360 pt phone', () {
    for (final kind in GestureFailureKind.values) {
      for (final scale in const [1.0, 1.3]) {
        testWidgets('${kind.name} card at text scale $scale: no overflow, '
            'inside 360 pt', (t) async {
          _phone(t, width: 360);
          final s = _Backing().store();
          await _record(s, 'a', kind: kind);
          await t.pumpWidget(_Rig().card(s, scale: scale));
          expect(t.takeException(), isNull);
          final r = t.getRect(find.byKey(_cardKey));
          expect(r.left, greaterThanOrEqualTo(0));
          expect(r.right, lessThanOrEqualTo(360));
          for (final k in const [
            'gesture-failure-save',
            'gesture-failure-report',
            'gesture-failure-dismiss',
          ]) {
            final b = t.getRect(find.byKey(ValueKey(k)));
            expect(b.right, lessThanOrEqualTo(360), reason: k);
            expect(b.left, greaterThanOrEqualTo(0), reason: k);
          }
        });
      }
    }
  });

  group('Home', () {
    test('home_screen.dart places the card beside the community nudge, fed '
        'by AppState.gestureFailures', () {
      final src = File('lib/ui2/screens/home_screen.dart').readAsStringSync();
      final code = codeOnly(src);
      expect(src, contains('gesture_failure_card.dart'));
      expect(code, contains('GestureFailureCard('));
      expect(code, contains('gestureFailures'));
      final card = code.indexOf('GestureFailureCard(');
      final nudge = code.indexOf('CommunityNudge()');
      expect((card - nudge).abs(), lessThan(1200),
          reason: 'the two cards sit together under the rings');
    });
  });
}
