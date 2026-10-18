// Round 2, P1 privacy. A reviewed moment carries health answers (a medication
// label, a dose, a symptom). "Tasker connection" is ON by default and a plain
// broadcast reaches every app, so the review's export is
//   * its own setting, "Send reviewed moments to Tasker", OFF by default, drawn
//     but disabled while the Tasker connection is off (never hidden), and
//   * addressed to Tasker's package only (`package` argument of `emit_event`;
//     NativeChannels.kt calls Intent.setPackage; Kotlin is not testable here).
// The other event (SYNC_COMPLETE) keeps its open contract: no package.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/moment_follow_ups.dart';
import 'package:openstrap_edge/platform/tasker_bridge.dart';
import 'package:openstrap_edge/platform/tasker_moment_export.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../support/settings_sections.dart';

const _channel = MethodChannel('openstrap/tasker');
final _start = DateTime(2026, 10, 6, 9, 15);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    Prefs.setBool(Prefs.taskerConnection, true);
    Prefs.setBool(Prefs.taskerMomentExport, false);
    calls.clear();
    TaskerBridge.debugAndroidOverride = true;
    TaskerBridge.debugResetRateLimit();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (c) async {
      calls.add(c);
      return true;
    });
  });

  tearDown(() {
    TaskerBridge.debugAndroidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<void> send() => TaskerMomentExport()
      .exportAll([ReviewedItem(choice: MomentChoice.alcohol, start: _start, value: 2)]);

  group('the setting', () {
    test('its own key, and OFF unless somebody turned it on', () async {
      expect(Prefs.taskerMomentExport, 'tasker_moment_export');
      SharedPreferences.setMockInitialValues({});
      expect(Prefs.taskerMomentExportOn, isFalse);
    });

    test('it is independent of the Tasker connection switch', () {
      Prefs.setBool(Prefs.taskerConnection, true);
      expect(Prefs.taskerMomentExportOn, isFalse,
          reason: 'turning the connection on never consents to this');
    });
  });

  group('the gate', () {
    test('connection on, export OFF (the default): nothing leaves', () async {
      await send();
      expect(calls, isEmpty);
    });

    test('export on, connection OFF: nothing leaves', () async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      Prefs.setBool(Prefs.taskerConnection, false);
      await send();
      expect(calls, isEmpty);
    });

    test('both on: one broadcast', () async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      await send();
      expect(calls, hasLength(1));
      expect(calls.single.method, 'emit_event');
    });

    test('read at send time: switching it off stops the next send', () async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      final x = TaskerMomentExport();
      await x.exportAll([ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      Prefs.setBool(Prefs.taskerMomentExport, false);
      await x.exportAll([ReviewedItem(choice: MomentChoice.meal, start: _start)]);
      expect(calls, hasLength(1));
    });
  });

  group('the recipient', () {
    test('MOMENT_REVIEWED is addressed to Tasker\'s package only', () async {
      Prefs.setBool(Prefs.taskerMomentExport, true);
      await send();
      final args = Map<String, Object?>.from(calls.single.arguments as Map);
      expect(TaskerBridge.taskerPackage, 'net.dinglisch.android.taskerm');
      expect(args['package'], 'net.dinglisch.android.taskerm');
      expect(args['event'], 'MOMENT_REVIEWED');
    });

    test('SYNC_COMPLETE keeps its open contract: no package', () async {
      await TaskerBridge.emitSyncComplete(records: 3);
      final args = Map<String, Object?>.from(calls.single.arguments as Map);
      expect(args.containsKey('package'), isFalse);
    });

    test('emitEvent passes a package through only when given', () async {
      await TaskerBridge.emitEvent('X', package: 'a.b.c', rateLimited: false);
      await TaskerBridge.emitEvent('Y', rateLimited: false);
      expect((calls[0].arguments as Map)['package'], 'a.b.c');
      expect((calls[1].arguments as Map).containsKey('package'), isFalse);
    });
  });

  group('Automation settings', () {
    final row = find.byKey(const ValueKey('tasker-moment-export'));
    Finder sw() => find.descendant(of: row, matching: find.byType(Switch));

    testWidgets('drawn, OFF by default, and reports a change when the '
        'connection is on', (t) async {
      final changes = <bool>[];
      await pumpTall(
          t,
          AutomationSettingsView(
              token: 'tok',
              taskerOn: true,
              onTaskerOn: (_) {},
              onMomentExportOn: changes.add));
      expect(row, findsOneWidget);
      expect(find.descendant(of: row, matching: find.text('Send reviewed moments to Tasker')),
          findsOneWidget);
      expect(t.widget<Switch>(sw()).value, isFalse);
      expect(t.widget<Switch>(sw()).onChanged, isNotNull);
      await t.tap(sw());
      await t.pumpAndSettle();
      expect(changes, [true]);
    });

    testWidgets('connection off: drawn but disabled (never hidden)',
        (t) async {
      await pumpTall(
          t,
          AutomationSettingsView(
              token: 'tok',
              taskerOn: false,
              onTaskerOn: (_) {},
              momentExportOn: true,
              onMomentExportOn: (_) {}));
      expect(row, findsOneWidget);
      expect(t.widget<Switch>(sw()).onChanged, isNull);
    });

    testWidgets('its sub-text says what is sent and that it is health data',
        (t) async {
      await pumpTall(t, AutomationSettingsView(token: 'tok', taskerOn: true));
      final text = find.descendant(of: row, matching: find.byType(Text));
      final all = t.widgetList<Text>(text).map((w) => w.data ?? '').join(' ');
      expect(all.toLowerCase(), contains('health'));
      expect(all.toLowerCase(), contains('tasker'));
    });
  });
}
