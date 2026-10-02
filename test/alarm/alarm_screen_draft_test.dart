// 8O — the alarm screen edits a draft. Save / Cancel sit at the top, nothing is
// saved or sent while editing, and leaving with unsaved work asks first.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:openstrap_edge/state/alarm_draft.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SettingsAccordion;
import 'package:openstrap_edge/ui2/ui2.dart';

import '../phase8/support/sections.dart';

final _saved = fillDefaultAlarmSchedule(const [
  AlarmScheduleEntry(weekday: 0, hour: 6, minute: 30, enabled: true),
]);

class _Saves {
  final calls = <List<AlarmScheduleEntry>>[];
  AlarmSaveOutcome outcome = const AlarmSaveOutcome(AlarmSaveStatus.sentToBand);
  Completer<AlarmSaveOutcome>? gate;

  Future<AlarmSaveOutcome> call(List<AlarmScheduleEntry> e) {
    calls.add(e);
    return gate?.future ?? Future.value(outcome);
  }
}

AlarmScreenView _view(_Saves s, {bool connected = true}) => AlarmScreenView(
  connected: connected,
  schedule: _saved,
  now: DateTime(2026, 10, 5, 22, 0),
  onSave: s.call,
);

Future<void> _pump(WidgetTester t, Widget w) => pumpTall(t, w);

/// The day rows of the Alarm section, by weekday label.
Finder _dayRow(String label) =>
    find.descendant(of: section('Alarm'), matching: find.text(label));

Finder _headerButton(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(BigButton)).first;

bool _enabled(WidgetTester t, String label) =>
    !isDimmed(t, find.text(label)) &&
    t.widget<BigButton>(_headerButton(label)).onTap != null;

Future<void> _tapText(WidgetTester t, String text) async {
  await t.tap(find.text(text).first);
  await t.pumpAndSettle();
}

/// Pushes [view] on top of a launcher page, so a pop is observable.
Future<void> _launch(WidgetTester t, Widget view) async {
  t.view.physicalSize = const Size(1170, 24000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Builder(
        builder: (c) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(
                c,
              ).push(MaterialPageRoute<void>(builder: (_) => view)),
              child: const Text('launcher'),
            ),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('launcher'));
  await t.pumpAndSettle();
}

Future<void> _navBack(WidgetTester t) async {
  await t.tap(find.byIcon(LucideIcons.chevronLeft));
  await t.pumpAndSettle();
}

Finder get _onScreen => find.byType(AlarmScreenView);
Finder _dialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  group('header', () {
    testWidgets('Save and Cancel are at the top, above every section, dimmed '
        'while there is nothing to save', (t) async {
      final s = _Saves();
      await _pump(t, _view(s));
      final top = t.getTopLeft(find.byType(SettingsAccordion).first).dy;
      expect(t.getTopLeft(find.text('Save')).dy, lessThan(top));
      expect(t.getTopLeft(find.text('Cancel')).dy, lessThan(top));
      expect(_enabled(t, 'Save'), isFalse);
      expect(_enabled(t, 'Cancel'), isFalse);
      await t.tap(find.text('Save'), warnIfMissed: false);
      expect(s.calls, isEmpty);
    });

    testWidgets('editing changes only the draft: nothing is saved or sent', (
      t,
    ) async {
      final s = _Saves();
      await _pump(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      expect(s.calls, isEmpty, reason: 'no save while editing');
      expect(_enabled(t, 'Save'), isTrue);
      expect(_enabled(t, 'Cancel'), isTrue);
      expect(find.textContaining('Unsaved changes'), findsOneWidget);
    });

    testWidgets('an editable row works with the band disconnected', (t) async {
      final s = _Saves();
      await _pump(t, _view(s, connected: false));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      expect(
        _enabled(t, 'Save'),
        isTrue,
        reason: 'edits are a draft, so they do not need the band',
      );
    });

    testWidgets('Cancel puts the saved schedule back and sends nothing', (
      t,
    ) async {
      final s = _Saves();
      await _pump(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _tapText(t, 'Cancel');
      expect(s.calls, isEmpty);
      expect(_enabled(t, 'Save'), isFalse);
      expect(_enabled(t, 'Cancel'), isFalse);
      expect(find.textContaining('Unsaved changes'), findsNothing);
    });

    testWidgets('Save hands the whole week over once and reports the outcome', (
      t,
    ) async {
      final s = _Saves();
      await _pump(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _tapText(t, 'Save');
      expect(s.calls, hasLength(1));
      expect(s.calls.single, hasLength(7));
      expect(s.calls.single[1].enabled, isTrue);
      expect(find.text('Saved and sent to the band'), findsOneWidget);
      expect(_enabled(t, 'Save'), isFalse, reason: 'clean again');
    });

    testWidgets('offline Save says the band updates later', (t) async {
      final s = _Saves()
        ..outcome = const AlarmSaveOutcome(AlarmSaveStatus.savedOffline);
      await _pump(t, _view(s, connected: false));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _tapText(t, 'Save');
      expect(
        find.text('Saved — the band updates when it next connects'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a failed band update shows the reason and a Retry that works',
      (t) async {
        final s = _Saves()
          ..outcome = const AlarmSaveOutcome(
            AlarmSaveStatus.failed,
            error: 'the band did not take the alarm',
          );
        await _pump(t, _view(s));
        await t.tap(_dayRow('Tue'));
        await t.pumpAndSettle();
        await _tapText(t, 'Save');
        expect(
          find.textContaining('the band did not take the alarm'),
          findsOneWidget,
        );
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Save'), findsNothing);
        expect(_enabled(t, 'Retry'), isTrue);
        s.outcome = const AlarmSaveOutcome(AlarmSaveStatus.sentToBand);
        await _tapText(t, 'Retry');
        expect(s.calls, hasLength(2));
        expect(find.text('Saved and sent to the band'), findsOneWidget);
      },
    );

    testWidgets('a Save that reached nothing keeps the edits and says so', (
      t,
    ) async {
      final s = _Saves()
        ..outcome = const AlarmSaveOutcome(
          AlarmSaveStatus.failed,
          persisted: false,
          error: 'disk full',
        );
      await _pump(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _tapText(t, 'Save');
      expect(find.textContaining('Not saved: disk full'), findsOneWidget);
      expect(_enabled(t, 'Cancel'), isTrue, reason: 'still unsaved');
    });
  });

  group('leave guard', () {
    testWidgets('a clean screen leaves at once', (t) async {
      await _launch(t, _view(_Saves()));
      expect(_onScreen, findsOneWidget);
      await _navBack(t);
      expect(_onScreen, findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('unsaved edits: the nav-bar back opens Save / Discard / Keep '
        'editing', (t) async {
      await _launch(t, _view(_Saves()));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _navBack(t);
      expect(_onScreen, findsOneWidget, reason: 'did not leave');
      for (final b in ['Save', 'Discard', 'Keep editing']) {
        expect(_dialog(b), findsOneWidget, reason: b);
      }
    });

    testWidgets('system back is guarded the same way', (t) async {
      await _launch(t, _view(_Saves()));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(_onScreen, findsOneWidget);
      expect(_dialog('Discard'), findsOneWidget);
    });

    testWidgets('Keep editing stays, with the draft intact', (t) async {
      final s = _Saves();
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _navBack(t);
      await t.tap(_dialog('Keep editing'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_onScreen, findsOneWidget);
      expect(_enabled(t, 'Save'), isTrue, reason: 'the draft survived');
      expect(s.calls, isEmpty);
    });

    testWidgets('Discard leaves and saves nothing', (t) async {
      final s = _Saves();
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _navBack(t);
      await t.tap(_dialog('Discard'));
      await t.pumpAndSettle();
      expect(_onScreen, findsNothing);
      expect(s.calls, isEmpty);
    });

    testWidgets('Save in the dialog saves once, then leaves', (t) async {
      final s = _Saves();
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _navBack(t);
      await t.tap(_dialog('Save'));
      await t.pumpAndSettle();
      expect(s.calls, hasLength(1));
      expect(_onScreen, findsNothing);
    });

    testWidgets('Save in the dialog that fails stays, and offers Retry', (
      t,
    ) async {
      final s = _Saves()
        ..outcome = const AlarmSaveOutcome(
          AlarmSaveStatus.failed,
          error: 'link dropped',
        );
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _navBack(t);
      await t.tap(_dialog('Save'));
      await t.pumpAndSettle();
      expect(_onScreen, findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('still sending to the band: Wait / Leave; Leave goes, and the '
        'send finishing later is harmless', (t) async {
      final s = _Saves()..gate = Completer<AlarmSaveOutcome>();
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pump();
      await _navBack(t);
      expect(_dialog('Wait'), findsOneWidget);
      expect(_dialog('Leave'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await t.tap(_dialog('Leave'));
      await t.pumpAndSettle();
      expect(_onScreen, findsNothing);
      s.gate!.complete(const AlarmSaveOutcome(AlarmSaveStatus.sentToBand));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
    });

    testWidgets('still sending: Wait holds until the band answers, then '
        'leaves', (t) async {
      final s = _Saves()..gate = Completer<AlarmSaveOutcome>();
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await t.tap(find.text('Save'));
      await t.pump();
      await _navBack(t);
      await t.tap(_dialog('Wait'));
      await t.pumpAndSettle();
      expect(_onScreen, findsOneWidget, reason: 'still waiting');
      s.gate!.complete(const AlarmSaveOutcome(AlarmSaveStatus.sentToBand));
      await t.pumpAndSettle();
      expect(_onScreen, findsNothing);
    });

    testWidgets('after a Save whose band update failed, leaving is allowed '
        '(the schedule itself is saved)', (t) async {
      final s = _Saves()
        ..outcome = const AlarmSaveOutcome(
          AlarmSaveStatus.failed,
          error: 'link dropped',
        );
      await _launch(t, _view(s));
      await t.tap(_dayRow('Tue'));
      await t.pumpAndSettle();
      await _tapText(t, 'Save');
      await _navBack(t);
      expect(_onScreen, findsNothing);
    });
  });
}
