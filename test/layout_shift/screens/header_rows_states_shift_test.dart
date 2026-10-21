// Row 1 never changes height between idle / syncing / failed / importing /
// recalculating, at any width or text scale, in English or German: the block
// rect, the status line's rect and the content anchor below are identical to
// the idle ones. (A wrapped action cluster used to grow row 1 at 360 pt x 2.0.)
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/clock_format.dart';
import 'package:openstrap_edge/state/derive_progress.dart';
import 'package:openstrap_edge/state/control_operations.dart';

import 'package:openstrap_edge/ui2/grammar.dart' show Pressable;

import '../../support/bundled_fonts.dart';
import '../../support/header_rows_fakes.dart';

const _widths = [320.0, 340.0, 360.0, 375.0, 390.0];
const _scales = [1.0, 1.15, 1.3, 1.5, 2.0];

SyncPresentationState _failedLong() => SyncPresentationState(
      phase: 'failed',
      failureReason:
          'The band stopped answering while downloading; move closer and retry',
      lastSuccess: headerNow.subtract(const Duration(minutes: 61)),
      startedAt: headerNow.subtract(const Duration(seconds: 50)),
      finishedAt: headerNow.subtract(const Duration(seconds: 9)),
    );

SyncPresentationState _longRunning() {
  final base = headerSyncing();
  return SyncPresentationState(
    phase: base.phase,
    busy: true,
    contactedBand: true,
    startedAt: headerNow.subtract(const Duration(minutes: 74, seconds: 5)),
    lastSuccess: base.lastSuccess,
    steps: base.steps,
  );
}

/// A finished sync that left more to do: "Needs another pass" with BOTH
/// Show details and Sync now (wider than Show details + Retry).
SyncPresentationState _partial() => SyncPresentationState(
      phase: 'completed',
      partial: true,
      lastSuccess: headerNow.subtract(const Duration(minutes: 5)),
      startedAt: headerNow.subtract(const Duration(minutes: 3)),
      finishedAt: headerNow.subtract(const Duration(minutes: 1)),
    );

typedef _Setup = void Function(HeaderApp app);

final _states = <String, _Setup>{
  'idle': (a) {},
  'syncing': (a) => a.pres = headerSyncing(),
  'syncing 1 h 14 m': (a) => a.pres = _longRunning(),
  'failed': (a) => a.pres = headerFailed(),
  'completed, partial': (a) => a.pres = _partial(),
  'failed, long reason': (a) => a.pres = _failedLong(),
  'importing': (a) => a.importProgress.value = const ImportCopying(
      ImportStage.journal, 10, 100, 4, 9),
  'recalculating': (a) =>
      a.derive.value = const DeriveProgress(dayIndex: 3, dayTotal: 40),
};

/// (block rect, status-line rect, anchor top-left) as strings.
List<String> _geometry(WidgetTester t) => [
      'block ${t.getRect(find.byKey(const ValueKey('shared:header-rows')))}',
      'row1 ${t.getRect(find.byKey(const ValueKey('shared:status-line')))}',
      'anchor ${t.getTopLeft(find.byKey(headerAnchorKey))}',
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    h24();
  });
  tearDown(ClockFormatController.debugReset);

  Future<List<String>> measure(WidgetTester t, String state, double w,
      double scale, Locale? locale) async {
    final app = HeaderApp(pres: headerIdle(), through: headerEdge);
    _states[state]!(app);
    addTearDown(app.dispose);
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(w, 900);
    await t.pumpWidget(titleOnly(app, 'Sleep', scale: scale, locale: locale));
    await t.pump();
    final g = _geometry(t);
    await t.pumpWidget(const SizedBox());
    return g;
  }

  for (final locale in [null, const Locale('de')]) {
    for (final w in _widths) {
      for (final scale in _scales) {
        testWidgets(
            'every state keeps the block, row 1 and the anchor put: '
            '${w.toInt()} pt x $scale ${locale?.languageCode ?? 'en'}',
            (t) async {
          addTearDown(t.view.reset);
          await withClock(Clock.fixed(headerNow), () async {
            final idle = await measure(t, 'idle', w, scale, locale);
            for (final s in _states.keys.skip(1)) {
              final g = await measure(t, s, w, scale, locale);
              expect(g, idle, reason: '$s differs from idle');
            }
          });
        });
      }
    }
  }

  // Actions are never scaled and always have a 44 x 44 target, whatever the
  // width and text scale; when they do not fit on row 1 they get their own
  // reserved line (checked above: every state keeps the same block).
  const actionsByState = {
    'idle': ['Sync now'],
    'syncing': ['Show details'],
    'failed': ['Show details', 'Retry'],
    'completed, partial': ['Show details', 'Sync now'],
  };
  for (final w in _widths) {
    for (final scale in _scales) {
      testWidgets('actions are unscaled with 44 pt targets: '
          '${w.toInt()} pt x $scale', (t) async {
        addTearDown(t.view.reset);
        await withClock(Clock.fixed(headerNow), () async {
          for (final e in actionsByState.entries) {
            final app = HeaderApp(pres: headerIdle(), through: headerEdge);
            _states[e.key]!(app);
            addTearDown(app.dispose);
            t.view.devicePixelRatio = 1;
            t.view.physicalSize = Size(w, 900);
            await t.pumpWidget(titleOnly(app, 'Sleep', scale: scale));
            await t.pump();
            // Show details opens a sheet whose barrier eats later taps.
            for (final label in [
              ...e.value.where((l) => l != 'Show details'),
              ...e.value.where((l) => l == 'Show details'),
            ]) {
              final f = find.text(label);
              expect(f, findsOneWidget, reason: '${e.key}: $label');
              final why = '${e.key} $label at $w x $scale';
              expect(find.descendant(
                      of: find.byKey(const ValueKey('shared:header-rows')),
                      matching: find.ancestor(of: f, matching: find.byType(FittedBox))),
                  findsNothing, reason: 'scaled by a FittedBox: $why');
              expect(find.descendant(
                      of: find.byKey(const ValueKey('shared:header-rows')),
                      // (Pressable's own press feedback is a Transform at rest.)
                      matching: find.ancestor(
                          of: find.ancestor(
                              of: f, matching: find.byType(Pressable)),
                          matching: find.byType(Transform))),
                  findsNothing, reason: 'transformed: $why');
              expect(t.renderObject<RenderParagraph>(f).textScaler.scale(10),
                  closeTo(10 * scale, 0.01), reason: 'text scale: $why');
              final hit = t.getRect(
                  find.ancestor(of: f, matching: find.byType(Pressable)).first);
              expect(hit.width, greaterThanOrEqualTo(44), reason: 'width: $why');
              expect(hit.height, greaterThanOrEqualTo(44), reason: 'height: $why');
              // The whole target is inside the block, and a tap at its far
              // corner lands (nothing pushed out of its parent's bounds).
              final block =
                  t.getRect(find.byKey(const ValueKey('shared:header-rows')));
              expect(hit.left, greaterThanOrEqualTo(block.left - 0.01),
                  reason: 'left outside the block: $why');
              expect(hit.right, lessThanOrEqualTo(block.right + 0.01),
                  reason: 'right outside the block: $why');
              expect(hit.bottom, lessThanOrEqualTo(block.bottom + 0.01),
                  reason: 'bottom outside the block: $why');
              await t.tapAt(hit.bottomRight - const Offset(1, 1));
              await t.pump();
              if (label == 'Show details') {
                expect(find.byType(BottomSheet), findsOneWidget,
                    reason: 'far-corner tap missed: $why');
              } else {
                expect(app.syncs, 1, reason: 'far-corner tap missed: $why');
              }
            }
            await t.pumpWidget(const SizedBox());
          }
        });
      });
    }
  }
}
