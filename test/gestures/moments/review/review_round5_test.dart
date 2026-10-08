// Round 5. The consent switch renders ONE shared state (AckedBool: value =
// last confirmed or the pending write's optimistic value, pending, failed) and
// keeps no copy of its own:
//  - consent ON, tap OFF, leave and reopen before the write is acknowledged,
//    then the write FAILS: the reopened screen shows ON and the error
//  - success path; a second screen instance mirrors the state live; the error
//    clears on the next success
// No real time: every write is a Completer the test releases.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/acked_bool.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/settings_sections.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = Prefs.taskerMomentExport;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    AckedBool.resetForTest();
  });

  final row = find.byKey(const ValueKey('tasker-moment-export'));
  Finder sw([Finder? within]) => find.descendant(
      of: within ?? find.byType(AutomationSettings),
      matching: find.descendant(of: row, matching: find.byType(Switch)));
  final err = find.byKey(const ValueKey('tasker-moment-export-error'));

  /// A write that stores the value in the cache at once (as the platform does)
  /// and answers when the test says.
  Future<bool> Function(String, bool) held(Completer<bool> gate) => (k, v) {
        Prefs.setBool(k, v);
        return gate.future;
      };

  group('state (pure)', () {
    test('value is the optimistic one while pending, the confirmed one after',
        () async {
      Prefs.setBool(key, true);
      final b = AckedBool.forKey(key);
      final gate = Completer<bool>();
      expect(b.value, isTrue);
      final f = b.set(false, write: held(gate));
      expect(b.pending, isTrue);
      expect(b.value, isFalse, reason: 'optimistic');
      gate.complete(true);
      expect(await f, isTrue);
      expect(b.pending, isFalse);
      expect(b.value, isFalse);
      expect(b.failed, isFalse);
    });

    test('a failure publishes the confirmed value and the error; the next '
        'success clears the error', () async {
      Prefs.setBool(key, true);
      final b = AckedBool.forKey(key);
      var notified = 0;
      b.addListener(() => notified++);
      expect(await b.set(false, write: (k, v) async => false), isFalse);
      expect(b.value, isTrue);
      expect(b.failed, isTrue);
      expect(notified, greaterThanOrEqualTo(2), reason: 'start and end');
      expect(
          await b.set(false, write: (k, v) async {
            Prefs.setBool(k, v);
            return true;
          }),
          isTrue);
      expect(b.value, isFalse);
      expect(b.failed, isFalse);
    });

    test('a write that does not store into the cache itself still publishes '
        'what it confirmed', () async {
      Prefs.setBool(key, false);
      final b = AckedBool.forKey(key);
      expect(await b.set(true, write: (k, v) async => true), isTrue);
      expect(b.value, isTrue);
      expect(Prefs.taskerMomentExportOn, isTrue);
    });
  });

  group('screen', () {
    testWidgets('REOPENED during a failing OFF write: shows ON and the error',
        (t) async {
      Prefs.setBool(key, true);
      final gate = Completer<bool>();
      await pumpTall(t, AutomationSettings(setBoolAcked: held(gate)));
      await t.tap(sw());
      await t.pump();
      expect(t.widget<Switch>(sw()).value, isFalse, reason: 'optimistic');
      // Leave, and reopen before the write is acknowledged.
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      await pumpTall(t, const AutomationSettings());
      expect(t.widget<Switch>(sw()).value, isFalse, reason: 'still pending');
      expect(t.widget<Switch>(sw()).onChanged, isNull);
      expect(err, findsNothing);
      // The write fails: consent is still ON, and the screen must say so.
      gate.complete(false);
      await t.pumpAndSettle();
      expect(Prefs.taskerMomentExportOn, isTrue);
      expect(t.widget<Switch>(sw()).value, isTrue,
          reason: 'the switch shows what is stored');
      expect(t.widget<Switch>(sw()).onChanged, isNotNull);
      expect(err, findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('success: the switch follows, no error', (t) async {
      Prefs.setBool(key, true);
      final gate = Completer<bool>();
      await pumpTall(t, AutomationSettings(setBoolAcked: held(gate)));
      await t.tap(sw());
      await t.pump();
      expect(t.widget<Switch>(sw()).value, isFalse);
      gate.complete(true);
      await t.pumpAndSettle();
      expect(t.widget<Switch>(sw()).value, isFalse);
      expect(t.widget<Switch>(sw()).onChanged, isNotNull);
      expect(Prefs.taskerMomentExportOn, isFalse);
      expect(err, findsNothing);
    });

    testWidgets('a second screen instance mirrors the state live, and the '
        'error clears on the next success', (t) async {
      Prefs.setBool(key, true);
      final gate = Completer<bool>();
      final a = UniqueKey(), b = UniqueKey();
      t.view.physicalSize = const Size(1170, 24000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          home: Stack(children: [
        AutomationSettings(key: a, setBoolAcked: held(gate)),
        Offstage(child: AutomationSettings(key: b)),
      ])));
      await t.pumpAndSettle();
      final onA = sw(find.byKey(a));
      // B is offstage: it is only read, never tapped.
      final inB = find.descendant(
          of: find.byKey(b, skipOffstage: false),
          matching: find.descendant(
              of: find.byKey(const ValueKey('tasker-moment-export'),
                  skipOffstage: false),
              matching: find.byType(Switch, skipOffstage: false),
              skipOffstage: false),
          skipOffstage: false);
      await t.tap(onA);
      await t.pump();
      expect(t.widget<Switch>(inB).value, isFalse, reason: 'B mirrors A');
      expect(t.widget<Switch>(inB).onChanged, isNull, reason: 'B is inert too');
      gate.complete(false);
      await t.pumpAndSettle();
      expect(t.widget<Switch>(onA).value, isTrue);
      expect(t.widget<Switch>(inB).value, isTrue);
      expect(
          find.descendant(
              of: find.byKey(b, skipOffstage: false),
              matching: find.byKey(
                  const ValueKey('tasker-moment-export-error'),
                  skipOffstage: false),
              skipOffstage: false),
          findsOneWidget,
          reason: 'the error shows on every instance');
      // The next write succeeds (a plain one: it stores into the cache).
      expect(
          await AckedBool.forKey(key).set(false, write: (k, v) async {
            Prefs.setBool(k, v);
            return true;
          }),
          isTrue);
      await t.pumpAndSettle();
      expect(t.widget<Switch>(onA).value, isFalse);
      expect(t.widget<Switch>(inB).value, isFalse);
      expect(err, findsNothing);
    });
  });
}
