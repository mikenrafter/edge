// Developer > Live streaming (lib/ui2/profile/live_devices.dart, the
// `LiveDevices` route over a real AppState) on a connected WHOOP 5/MG and a
// 4.0.
//
// User report: the screen "does not actually show any live streaming data nor
// allow you to connect live to … a WHOOP 5 MG band"; it should show live heart
// rate, the detected sensors and whatever else the device sends, as graphs,
// with a trivial way to enable the feeds.
//
// ASSUMED UI (all in the band's card; sensors paired alongside have no
// control, their streams are already on):
//   * a button with the text 'Start live feed' while the feed is off and
//     'Stop live feed' while it is on (state read from AppState.isLiveFeedOn,
//     so the label follows the app, not a local widget flag);
//   * only a CONNECTED band has the control; a disconnected one has neither;
//   * leaving the screen (dispose) while the feed is on stops it — through the
//     same AppState.stopLiveFeed, so the owner is released and the disable
//     commands go out (§4.3: nothing left streaming in the background);
//   * every stream key in the buffer gets a LiveStreamChart whose label carries
//     its unit (liveStreamLabel);
//   * a "sensors" list, `ValueKey('live-sensors:<deviceId>')`, in the band's
//     card, with one row per stream the band has reported, each row showing
//     liveStreamLabel(key).
// AppState API assumed: see test/support/live_stream_band_rig.dart and
// g6_start_stop_commands_test.dart.
//
// Timing: widget tests run in fake time, so the engine's 60/100 ms gaps between
// writes are advanced with pump(), never real delays.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_engine.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/profile/live_devices.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart';
import 'package:provider/provider.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/live_stream_band_rig.dart';

const _start = 'Start live feed';
const _stop = 'Stop live feed';
final _sensors = find.byKey(const ValueKey<String>('live-sensors:$kBandId'));

Future<void> _pumpScreen(WidgetTester t, G6Rig rig) async {
  t.view.physicalSize = const Size(1170, 15000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: rig.app,
    child: MaterialApp(
        theme: buildTheme(Brightness.light), home: const LiveDevices()),
  ));
  await t.pump();
}

/// Advance fake time past every 60/100 ms gap of a start/stop bundle.
Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox());
  await _settle(t);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BleEngine.resetBandClaimForTest();
  });
  tearDown(BleEngine.resetBandClaimForTest);

  group('the control', () {
    testWidgets('a connected MG offers Start; Stop is not shown yet',
        (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      expect(find.text(_start), findsOneWidget);
      expect(find.text(_stop), findsNothing);
      expect(rig.writes, isEmpty, reason: 'opening the screen arms nothing');
      await _unmount(t);
    });

    testWidgets('Start arms the MG and the button becomes Stop', (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      expect(rig.ops, [(Cmd.toggleRealtimeHr, 1), (Cmd.toggleImuMode, 1)]);
      expect(find.text(_stop), findsOneWidget);
      expect(find.text(_start), findsNothing);
      await _unmount(t);
    });

    testWidgets('Stop turns it off and the button goes back to Start',
        (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      rig.writes.clear();
      await t.tap(find.text(_stop));
      await _settle(t);
      expect(rig.ops, [(Cmd.toggleImuMode, 0), (Cmd.toggleRealtimeHr, 0)]);
      expect(find.text(_start), findsOneWidget);
      expect(feedOn(rig.app), isFalse);
      await _unmount(t);
    });

    testWidgets('leaving the screen while streaming stops the feed',
        (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      rig.writes.clear();
      await _unmount(t); // the route is popped / disposed
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse);
      expect(rig.ops, [(Cmd.toggleImuMode, 0), (Cmd.toggleRealtimeHr, 0)],
          reason: 'no stream left running behind a closed screen');
    });

    testWidgets('leaving while the band refuses the disable still releases it',
        (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      rig.throwing.addAll([Cmd.toggleImuMode, Cmd.toggleRealtimeHr]);
      await _unmount(t);
      expect(feedOn(rig.app), isFalse);
      expect(developerOwnerSet(rig.app), isFalse);
    });

    testWidgets('a disconnected band has no control', (t) async {
      final rig = G6Rig(connected: false);
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      expect(find.textContaining('Disconnected'), findsOneWidget);
      expect(find.text(_start), findsNothing);
      expect(find.text(_stop), findsNothing);
      await _unmount(t);
    });

    testWidgets('a connected 4.0 has it too, and sends the gen4 bundle',
        (t) async {
      final rig = G6Rig(band: BandProfile.gen4);
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      expect(rig.ops, [
        (Cmd.toggleRealtimeHr, 1),
        (Cmd.sendR10R11Realtime, 1),
        (Cmd.toggleImuMode, 1),
        (Cmd.enableOpticalData, 1),
      ]);
      for (final op in rig.opcodes) {
        expect(dangerousCmds, isNot(contains(op)));
      }
      expect(find.text(_stop), findsOneWidget);
      await _unmount(t);
    });
  });

  group('what the MG sends is graphed', () {
    const keys = [
      'hr',
      'rr',
      'accel_x',
      'accel_y',
      'accel_z',
      'gyro_x',
      'gyro_y',
      'gyro_z',
    ];

    Future<G6Rig> streaming(WidgetTester t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      rig.feed(hr28Inner(hr: 62, rr: [800, 810]));
      rig.feed(r21LiveInner());
      await t.pump(const Duration(seconds: 2)); // the screen's 1 s redraw
      return rig;
    }

    testWidgets('one LiveStreamChart per stream, each labelled with its unit',
        (t) async {
      await streaming(t);
      expect(find.byType(LiveStreamChart), findsNWidgets(keys.length));
      for (final k in keys) {
        final label = liveStreamLabel(k);
        expect(label, matches(RegExp(r'\(.+\)$')),
            reason: '$k label states its unit');
        expect(
            find.descendant(
                of: find.byType(LiveStreamChart), matching: find.text(label)),
            findsOneWidget,
            reason: k);
      }
      await _unmount(t);
    });

    testWidgets('every graph is scrubbable like the rest of the app',
        (t) async {
      await streaming(t);
      for (final chart in find.byType(LiveStreamChart).evaluate()) {
        expect(
            find.descendant(
                of: find.byWidget(chart.widget),
                matching: find.byType(ChartScrub)),
            findsOneWidget);
      }
      await _unmount(t);
    });

    testWidgets('the sensors list names every reported stream', (t) async {
      await streaming(t);
      expect(_sensors, findsOneWidget);
      for (final k in keys) {
        expect(
            find.descendant(
                of: _sensors, matching: find.text(liveStreamLabel(k))),
            findsOneWidget,
            reason: '$k listed as a sensor/stream');
      }
      await _unmount(t);
    });

    testWidgets('an unknown decoded field is graphed under its raw name',
        (t) async {
      final rig = await streaming(t);
      rig.feed(hr28V2Inner(hr: 71, location: 3));
      rig.feed(hr28V2Inner(hr: 72, location: 4, ts: nowSec() + 1));
      await t.pump(const Duration(seconds: 2));
      expect(
          find.descendant(
              of: find.byType(LiveStreamChart), matching: find.text('location')),
          findsOneWidget);
      expect(
          find.descendant(of: _sensors, matching: find.text('location')),
          findsOneWidget);
      await _unmount(t);
    });

    testWidgets('a gen5 band that has reported nothing draws no fake graph',
        (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await _pumpScreen(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      expect(find.byType(LiveStreamChart), findsNothing);
      await _unmount(t);
    });
  });

  // The same live devices as a tab of the Device lab (no screen of their own).
  group('as the Device lab\'s Live tab', () {
    Future<void> pumpLab(WidgetTester t, G6Rig rig) async {
      t.view.physicalSize = const Size(1170, 15000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: rig.app,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: const DeviceLabView(
            ecgSupported: false,
            initialTab: LabTab.live,
            live: LiveDevices(embedded: true),
          ),
        ),
      ));
      await t.pump();
    }

    testWidgets('the control is there, under the lab\'s title, with no '
        'second title', (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await pumpLab(t, rig);
      expect(find.text(_start), findsOneWidget);
      expect(find.text('Device lab'), findsOneWidget);
      expect(find.text('Live devices'), findsNothing);
      await _unmount(t);
    });

    testWidgets('leaving the Live tab while streaming stops the feed',
        (t) async {
      final rig = G6Rig();
      addTearDown(rig.dispose);
      await pumpLab(t, rig);
      await t.tap(find.text(_start));
      await _settle(t);
      expect(feedOn(rig.app), isTrue);
      rig.writes.clear();
      await t.tap(find.byKey(const ValueKey('device-lab-tab:logs')));
      await _settle(t);
      expect(feedOn(rig.app), isFalse);
      expect(rig.ops, [(Cmd.toggleImuMode, 0), (Cmd.toggleRealtimeHr, 0)],
          reason: 'no stream left running behind another tab');
      await _unmount(t);
    });
  });
}
