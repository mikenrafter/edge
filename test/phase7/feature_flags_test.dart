// Phase 7 — the five rollout switches. Defaults are ON (shipped behaviour);
// each OFF path falls back to the old behaviour or hides the feature cleanly.

import 'dart:io';

import 'package:flutter/material.dart' show Widget;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/double_tap_repeat.dart';
import 'package:openstrap_edge/gestures/gesture_dispatcher.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';
import 'package:openstrap_edge/notify/notification_relay.dart';
import 'package:openstrap_edge/state/alarm_schedule.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/feature_flags.dart';
import 'package:openstrap_edge/ui2/profile/alarm.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart' show DeviceLabView;
import 'package:openstrap_edge/ui2/profile/devices.dart'
    show showSignalPriorityEntry, showSourceCatalogEntry;
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/wake/wake_controller.dart';
import 'package:openstrap_edge/wake/wake_orchestrator.dart';
import 'package:openstrap_edge/wake/wake_settings.dart';

import '../phase8/support/sections.dart';

/// What a screen is handed: process-wide flags as they are now, no band.
Capabilities _caps() => Capabilities(CapabilityInputs.detached());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'phase7_feature_flags_test.db';
  });
  setUp(() async {
    FeatureFlags.resetForTest();
    await LocalDb.close();
    await databaseFactory.deleteDatabase(
      p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName),
    );
    SharedPreferences.setMockInitialValues({'notif_quiet_enabled': false});
  });
  tearDownAll(LocalDb.close);

  group('mechanism', () {
    test('every flag is ON by default', () {
      for (final f in FeatureFlag.values) {
        expect(FeatureFlags.isOn(f), isTrue, reason: f.id);
        expect(FeatureFlags.defaultOf(f), isTrue, reason: f.id);
      }
      expect(FeatureFlag.values.map((f) => f.id).toSet().length, 5);
    });

    test('a stored local value overrides the default, per flag', () async {
      SharedPreferences.setMockInitialValues({'ff.natural_wake': false});
      await FeatureFlags.load();
      expect(FeatureFlags.isOn(FeatureFlag.naturalWake), isFalse);
      for (final f in FeatureFlag.values.where((f) => f != FeatureFlag.naturalWake)) {
        expect(FeatureFlags.isOn(f), isTrue, reason: f.id);
      }
    });

    test('set persists and clear returns to the default', () async {
      await FeatureFlags.set(FeatureFlag.nativeRelay, false);
      expect((await SharedPreferences.getInstance()).getBool('ff.native_relay'),
          isFalse);
      FeatureFlags.resetForTest();
      await FeatureFlags.load();
      expect(FeatureFlags.isOn(FeatureFlag.nativeRelay), isFalse);
      await FeatureFlags.clear(FeatureFlag.nativeRelay);
      expect(FeatureFlags.isOn(FeatureFlag.nativeRelay), isTrue);
    });

    test('a wrong-typed stored override (a foreign writer) reads as the default',
        () async {
      SharedPreferences.setMockInitialValues({'ff.natural_wake': 'off'});
      await FeatureFlags.load();
      expect(FeatureFlags.isOn(FeatureFlag.naturalWake), isTrue);
    });

    test('nothing in the mechanism touches the network', () {
      final src = File('lib/state/feature_flags.dart').readAsStringSync();
      for (final banned in ['http', 'dart:io', 'firebase', 'remote_config']) {
        expect(src.contains("import '$banned"), isFalse, reason: banned);
        expect(src.contains('package:$banned'), isFalse, reason: banned);
      }
    });
  });

  group('alertDispatcher', () {
    late int phoneShown, dispatcherPhone, dispatcherBand;
    late AlertDispatcher savedDispatcher;
    late Future<bool> Function(NotificationEvent, {bool allowPermissionPrompt})
        savedSink;

    setUp(() {
      phoneShown = dispatcherPhone = dispatcherBand = 0;
      final c = NotificationCenter.instance;
      savedDispatcher = c.dispatcher;
      savedSink = c.presentSink;
      c.presentSink = (e, {bool allowPermissionPrompt = true}) async {
        phoneShown++;
        return true;
      };
      c.dispatcher = AlertDispatcher(
        phone: () async {
          dispatcherPhone++;
          return true;
        },
        band: () async {
          dispatcherBand++;
          return true;
        },
        isConnected: () => true,
        ledger: const NotificationCenterDeliveryLedger(),
      );
    });
    tearDown(() {
      NotificationCenter.instance.dispatcher = savedDispatcher;
      NotificationCenter.instance.presentSink = savedSink;
    });

    Future<void> setRule(int destinations, {bool enabled = true}) async {
      final prefs = await NotificationPrefs.load();
      await prefs
          .withAlertRule(AlertRule(
            id: 'health',
            kind: 'health',
            enabled: enabled,
            destinations: destinations,
            channelPolicyId: 'health',
          ).toJson())
          .save();
    }

    NotificationEvent event(String key) => NotificationEvent(
          dedupeKey: key,
          category: NotifCategory.health,
          title: 't',
          body: 'b',
          date: todayLabel(),
          priority: NotifPriority.critical,
        );

    test('ON: phone and band both delivered through the dispatcher', () async {
      await setRule(3);
      final shown = await NotificationCenter.instance.emit(event('${todayLabel()}:on'));
      expect(shown, isTrue);
      expect(phoneShown, 1);
      expect(dispatcherBand, 1);
    });

    test('OFF: phone only, the dispatcher is not consulted, no band', () async {
      await setRule(3);
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, false);
      final shown = await NotificationCenter.instance.emit(event('${todayLabel()}:off'));
      expect(shown, isTrue);
      expect(phoneShown, 1);
      expect(dispatcherBand, 0);
      expect(dispatcherPhone, 0);
    });

    test('OFF: a band-only rule stays silent (no implicit phone alert)', () async {
      await setRule(2);
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, false);
      expect(await NotificationCenter.instance.emit(event('${todayLabel()}:bo')),
          isFalse);
      expect(phoneShown, 0);
      expect(dispatcherBand, 0);
    });

    test('OFF: a disabled rule stays silent', () async {
      await setRule(1, enabled: false);
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, false);
      expect(await NotificationCenter.instance.emit(event('${todayLabel()}:dis')),
          isFalse);
      expect(phoneShown, 0);
    });

    test('OFF: fire-once still holds (same dedupe key twice, one alert)', () async {
      await setRule(1);
      FeatureFlags.debugSet(FeatureFlag.alertDispatcher, false);
      final e = event('${todayLabel()}:twice');
      expect(await NotificationCenter.instance.emit(e), isTrue);
      expect(await NotificationCenter.instance.emit(e), isFalse);
      expect(phoneShown, 1);
    });
  });

  group('nativeRelay', () {
    const channel = MethodChannel('openstrap/notification_relay');
    late List<String> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add('${call.method}:${call.arguments}');
        return call.method == 'isPermissionGranted' ? true : null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    NotificationRelay relay() => NotificationRelay(
          buzz: () async {},
          isConnected: () => true,
          debugSupported: true,
        );

    test('ON: supported on Android', () {
      expect(relay().supported, isTrue);
    });

    test('OFF: unsupported, switching it on does nothing, UI hides it', () async {
      FeatureFlags.debugSet(FeatureFlag.nativeRelay, false);
      final r = relay();
      expect(r.supported, isFalse);
      expect(r.active, isFalse);
      await r.setEnabled(true);
      expect(r.enabled, isFalse);
      await r.setAppEnabled('com.example', true);
      expect(r.appCount, 0);
      expect(await r.requestPermission(), isFalse);
      expect(await r.refreshPermission(), isFalse);
    });

    test('OFF: bootstrap tells the platform to stop sending metadata', () async {
      FeatureFlags.debugSet(FeatureFlag.nativeRelay, false);
      await relay().bootstrap();
      expect(calls, ['setArmed:false']);
    });

    test('OFF on a phone that could never relay: the platform is not called',
        () async {
      FeatureFlags.debugSet(FeatureFlag.nativeRelay, false);
      await NotificationRelay(
        buzz: () async {},
        isConnected: () => true,
        debugSupported: false,
      ).bootstrap();
      expect(calls, isEmpty);
    });
  });

  group('sourceResolverUi', () {
    test('ON: catalog entry offered, priority editor always offered', () {
      expect(showSourceCatalogEntry(_caps()), isTrue);
      expect(showSignalPriorityEntry(_caps(), contended: false), isTrue);
      expect(showSignalPriorityEntry(_caps(), contended: true), isTrue);
    });

    test('OFF: no catalog entry; priority editor only under real contention', () {
      FeatureFlags.debugSet(FeatureFlag.sourceResolverUi, false);
      expect(showSourceCatalogEntry(_caps()), isFalse);
      expect(showSignalPriorityEntry(_caps(), contended: false), isFalse);
      expect(showSignalPriorityEntry(_caps(), contended: true), isTrue);
    });

    test('the screen builds its entry callbacks from those two helpers', () {
      final src = File('lib/ui2/profile/devices.dart').readAsStringSync();
      expect(src, contains('showSourceCatalogEntry(c.caps)'));
      expect(src, contains('showSignalPriorityEntry('));
    });
  });

  group('tapClassifiers', () {
    const channel = MethodChannel('openstrap/device_actions');
    final t0 = DateTime.utc(2026, 10, 2, 8);

    StrapEvent tap() {
      final ts = t0.millisecondsSinceEpoch ~/ 1000;
      return StrapEvent(
        eventId: 14,
        tsEpoch: ts,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true)
            .add(const Duration(seconds: 1)),
        hex: '',
        deviceId: 'band',
      );
    }

    Future<GestureSettings> mapped() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        return call.method == 'capabilities' ? <String>[] : false;
      });
      final s = GestureSettings();
      await s.bootstrap();
      await s.setDoubleTapActions({DeviceAction.logWater});
      await s.setActionsForTaps(3, {DeviceAction.markMoment});
      await s.setEcgOnDoubleTap(true);
      return s;
    }

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    test('OFF: a double tap runs its 2-tap actions at once; nothing counts',
        () async {
      FeatureFlags.debugSet(FeatureFlag.tapClassifiers, false);
      final s = await mapped();
      var counted = 0, ecgStarts = 0, windows = 0;
      final ran = <String>[];
      final session = DoubleTapRepeatSession(
        maxTaps: () => 5,
        window: () => const Duration(seconds: 3),
        onStarted: (_, _) => windows++,
      );
      final d = GestureDispatcher(
        settings: s,
        ecgSupported: () => true,
        onEcgTap: (_) async => ecgStarts++,
        onCountTaps: (_) async {
          counted++;
          return 3;
        },
        repeatSession: session,
        onLogWater: (_) async => ran.add('water'),
        onMarkMoment: (_) async => ran.add('moment'),
        claim: (_) async => true,
        release: (_) async {},
      );
      final out = await d.handle(tap());
      expect(out.single.status, GestureStatus.ran);
      expect(ran, ['water']);
      expect((counted, ecgStarts, windows), (0, 0, 0));
      expect(session.open, isFalse);
    });

    test('ON: the same setup starts the ECG lab instead', () async {
      final s = await mapped();
      var ecgStarts = 0;
      final d = GestureDispatcher(
        settings: s,
        ecgSupported: () => true,
        onEcgTap: (_) async => ecgStarts++,
        onLogWater: (_) async => fail('actions are suspended in the lab'),
        claim: (_) async => true,
        release: (_) async {},
      );
      await d.handle(tap());
      expect(ecgStarts, 1);
    });

    testWidgets('OFF hides every extra-tap control on the Gestures screen',
        (t) async {
      Widget view(bool counting) => BandGesturesView(
            chosen: const {},
            supported: {DeviceAction.none, DeviceAction.logWater},
            ecgSupported: true,
            onRepeatWindowMs: (_) {},
            onThresholds: (_) {},
            extraTaps: counting,
          );
      await pumpTall(t, view(true));
      for (final title in const [
        'Count extra taps with',
        'Tap counts',
        'What needs a WHOOP MG',
      ]) {
        expect(find.text(title), findsWidgets, reason: 'ON: $title');
      }
      // The pause and touch-window tuning moved to the Device lab (8AE), so
      // they are not on this screen with the flag on or off.
      for (final title in const ['Pause between double taps', 'Touch windows']) {
        expect(find.text(title), findsNothing, reason: 'ON: $title');
      }
      await pumpTall(t, view(false));
      for (final title in const [
        'Count extra taps with',
        'Tap counts',
        'Pause between double taps',
        'Touch windows',
        'What needs a WHOOP MG',
      ]) {
        expect(find.text(title), findsNothing, reason: 'OFF: $title');
      }
      expect(find.text('It does'), findsOneWidget);
    });

    testWidgets('OFF hides the lab\'s tap tools; the logs and probes stay',
        (t) async {
      Widget lab(bool tools) => DeviceLabView(
            ecgSupported: true,
            onRepeatWindowMs: (_) {},
            onThresholds: (_) {},
            tapTools: tools,
          );
      const tools = [
        'ECG on double tap',
        'Touch windows',
        'Repeated double taps',
      ];
      await pumpTall(t, lab(true));
      for (final title in tools) {
        expect(find.text(title), findsWidgets, reason: 'ON: $title');
      }
      await pumpTall(t, lab(false));
      for (final title in tools) {
        expect(find.text(title), findsNothing, reason: 'OFF: $title');
      }
      expect(find.text('Band events'), findsOneWidget);
      expect(find.text('Save lab log file'), findsOneWidget);
    });

    test('the lab gates its tap tools on the flag; the entry needs dev mode',
        () {
      final lab = File('lib/ui2/profile/device_lab.dart').readAsStringSync();
      expect(lab, contains('tapTools: caps.has(Feature.deviceLabTapTools)'));
      final devices = File('lib/ui2/profile/devices.dart').readAsStringSync();
      expect(devices, isNot(contains('onDeviceLab')));
      final settings = File('lib/ui2/profile/settings.dart').readAsStringSync();
      expect(settings, contains('onDeviceLab: () => goto(c, const DeviceLab())'));
    });
  });

  group('naturalWake', () {
    const wednesday = 2;
    final saved = fillDefaultAlarmSchedule([
      const AlarmScheduleEntry(
        weekday: wednesday,
        hour: 7,
        minute: 0,
        enabled: true,
        smartWindowMinutes: 30,
        naturalWindowMinutes: 45,
        gradualWindowMinutes: 30,
      ),
    ]);

    WakeController controller({WakeUpgradeState upgrade = WakeUpgradeState.acknowledged}) =>
        WakeController(
          schedule: () => saved,
          saveEntry: (_) async {},
          loadUpgradeState: () async => upgrade,
          saveUpgradeState: (_) async {},
          acknowledgeWake: (_) async => const WakeAckOutcome(
              nativeCancelRequested: false,
              nativeCancelled: false,
              fallbackArmed: true),
          traceFor: (_) async => const [],
        );

    test('ON: Natural is active and the new collection window follows it', () async {
      final c = controller();
      await c.reload();
      expect(c.naturalActive(wednesday), isTrue);
      expect(c.legacySmartWakeActive, isFalse);
      expect(c.configurationFor(wednesday), WakeConfiguration.both);
      expect(c.runningUpgradeState, WakeUpgradeState.acknowledged);
    });

    test('OFF: Natural never runs, the legacy Smart Wake path takes over', () async {
      FeatureFlags.debugSet(FeatureFlag.naturalWake, false);
      final c = controller();
      await c.reload();
      expect(c.naturalEnabled, isFalse);
      expect(c.naturalActive(wednesday), isFalse);
      expect(c.legacySmartWakeActive, isTrue);
      expect(c.configurationFor(wednesday), WakeConfiguration.gradualOnly);
      expect(c.runningUpgradeState, WakeUpgradeState.pending);
      // The collection lead uses the legacy Smart window, as it does today
      // while an upgrade explanation is pending.
      final armed = armedCollectionWindow(
        epoch: DateTime(2026, 10, 7, 7).millisecondsSinceEpoch ~/ 1000,
        schedule: saved,
        upgrade: c.runningUpgradeState,
      );
      expect(armed!.minutes, 30);
      final tl = c.timelineAt(DateTime(2026, 10, 7, 7));
      expect(tl.parts.map((p) => p.id), isNot(contains('natural')));
    });

    test('OFF leaves Gradual Wake and the native alarm in the timeline', () async {
      FeatureFlags.debugSet(FeatureFlag.naturalWake, false);
      final c = controller();
      await c.reload();
      final kinds = c.timelineAt(DateTime(2026, 10, 7, 7)).parts.map((p) => p.id);
      expect(kinds, contains('fallback'));
      expect(kinds, contains('gradual'));
    });

    test('gateNaturalWake: OFF is pending, ON passes the state through', () {
      for (final s in WakeUpgradeState.values) {
        expect(gateNaturalWake(s, enabled: true), s);
        expect(gateNaturalWake(s, enabled: false), WakeUpgradeState.pending);
      }
    });

    testWidgets('OFF hides the Natural row and the upgrade card, keeps Gradual',
        (t) async {
      Widget view(bool natural) => AlarmScreenView(
            connected: true,
            schedule: saved,
            now: DateTime(2026, 10, 5, 22),
            naturalWakeSupported: natural,
            upgradePending: natural,
            onSave: (_) async => throw UnimplementedError(),
          );
      await pumpTall(t, view(true));
      expect(find.text('Natural Wake'), findsWidgets);
      await pumpTall(t, view(false));
      expect(find.text('Natural Wake'), findsNothing);
      expect(find.text('Gradual Wake'), findsOneWidget);
    });

    test('AppState hands the orchestrator no Natural window when OFF', () {
      final src = File('lib/state/app_state.dart').readAsStringSync();
      expect(src,
          contains('naturalMinutes: wake.naturalEnabled ? entry.naturalWindowMinutes : 0'));
      expect(src, contains('wake.legacySmartWakeActive'));
    });
  });
}
