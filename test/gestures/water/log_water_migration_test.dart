// "Log water" is retired as a standalone gesture action (RED). It is now the
// Water answer of the marked-moment follow-up.
//
//   * The enum value and its wire id `log_water` STAY, so a stored mask or a
//     legacy id still decodes (the bitmask positions are frozen).
//   * It is no longer OFFERED: not in GestureSettings.supported, and the
//     gesture screen draws no row for it even when handed it.
//   * Loading prefs (GestureSettings.bootstrap) migrates every stored
//     assignment of log_water (double tap mask, 3/4/5-tap masks, the legacy
//     single id) to markMoment. If any migration happened, "Follow up about my
//     marked moments" is switched ON so those taps are still asked about.
//   * The migration is idempotent and persisted: a second load changes
//     nothing, and a user who then switches the follow-up off keeps it off.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/device_action.dart';
import 'package:openstrap_edge/gestures/gesture_settings.dart';
import 'package:openstrap_edge/ui2/profile/gestures.dart';
import 'package:openstrap_edge/ui2/profile/profile.dart' show SwitchRow;
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _maskKey = 'gesture_double_tap_actions';
const _tripleKey = 'gesture_tap_actions_3';
const _quadKey = 'gesture_tap_actions_4';
const _legacyKey = 'gesture_double_tap';
const _followKey = 'gesture_follow_up_moments';
const _sinceKey = 'gesture_follow_up_moments_since_ms';
const _channel = MethodChannel('openstrap/device_actions');

int _mask(Set<DeviceAction> a) => GestureSettings.maskOf(a);

Future<GestureSettings> _boot(Map<String, Object> prefs,
    {List<String> native = const ['torch']}) async {
  SharedPreferences.setMockInitialValues(prefs);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    if (call.method == 'capabilities') return native;
    return false;
  });
  final s = GestureSettings();
  await s.bootstrap();
  return s;
}

/// What a restart would load: the prefs as the first boot left them.
Future<Map<String, Object>> _stored() async {
  final p = await SharedPreferences.getInstance();
  return {for (final k in p.getKeys()) k: p.get(k)!};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));

  group('the value stays so old prefs decode', () {
    test('log_water is still an id, at its frozen bit', () {
      expect(DeviceActionX.fromId('log_water'), DeviceAction.logWater);
      expect(DeviceAction.logWater.id, 'log_water');
      expect(DeviceAction.values.indexOf(DeviceAction.logWater), 10);
      expect(GestureSettings.actionsOfMask(1 << 10), {DeviceAction.logWater});
    });
  });

  group('not offered', () {
    test('GestureSettings.supported has no log water; mark moment is there',
        () async {
      final s = await _boot({});
      expect(s.supported, isNot(contains(DeviceAction.logWater)));
      expect(s.supported, contains(DeviceAction.markMoment));
      expect(s.supported, contains(DeviceAction.workoutToggle));
    });

    for (final withIt in [true, false]) {
      testWidgets(
          'the gesture screen draws no Log water row'
          '${withIt ? ' even when it is handed supported and chosen' : ''}',
          (t) async {
        t.view.physicalSize = const Size(390 * 3, 2800 * 3);
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: BandGesturesView(
            chosen: {
              DeviceAction.markMoment,
              if (withIt) DeviceAction.logWater,
            },
            supported: {
              DeviceAction.none,
              DeviceAction.markMoment,
              DeviceAction.workoutToggle,
              if (withIt) DeviceAction.logWater,
            },
            replay: const {DeviceAction.markMoment},
            onToggle: (_, _) {},
            onReplay: (_, _) {},
            tapActions: const {3: {DeviceAction.markMoment}},
          ),
        ));
        await t.pumpAndSettle();
        expect(find.widgetWithText(SwitchRow, 'Log water'), findsNothing);
        expect(find.text('Log water'), findsNothing);
        // The neighbours are still there.
        expect(find.widgetWithText(SwitchRow, 'Mark a moment'), findsOneWidget);
        expect(
            find.widgetWithText(SwitchRow, 'Start / stop workout'),
            findsOneWidget);
      });
    }
  });

  group('a stored assignment loads as Mark a moment', () {
    test('double tap: log_water alone', () async {
      final s = await _boot({_maskKey: _mask({DeviceAction.logWater})});
      expect(s.doubleTapActions, {DeviceAction.markMoment});
      expect(s.actionsForTaps(2), {DeviceAction.markMoment});
    });

    test('double tap: it keeps the other actions beside it', () async {
      final s = await _boot(
          {_maskKey: _mask({DeviceAction.logWater, DeviceAction.torch})});
      expect(s.doubleTapActions, {DeviceAction.markMoment, DeviceAction.torch});
    });

    test('double tap: log_water AND mark_moment are one mark moment',
        () async {
      final s = await _boot({
        _maskKey: _mask({DeviceAction.logWater, DeviceAction.markMoment})
      });
      expect(s.doubleTapActions, {DeviceAction.markMoment});
    });

    test('3 and 4 taps migrate too, each in its own slot', () async {
      final s = await _boot({
        _tripleKey: _mask({DeviceAction.logWater}),
        _quadKey: _mask({DeviceAction.logWater, DeviceAction.torch}),
      });
      expect(s.actionsForTaps(3), {DeviceAction.markMoment});
      expect(s.actionsForTaps(4), {DeviceAction.markMoment, DeviceAction.torch});
      expect(s.actionsForTaps(2), isEmpty);
      expect(s.actionsForTaps(5), isEmpty);
    });

    test('the legacy single id (no mask yet) migrates', () async {
      final s = await _boot({_legacyKey: 'log_water'});
      expect(s.doubleTapActions, {DeviceAction.markMoment});
      expect(s.followUpMoments, isTrue);
    });

    test('the migrated mapping is written back (no log_water bit left)',
        () async {
      await _boot({
        _maskKey: _mask({DeviceAction.logWater, DeviceAction.torch}),
        _tripleKey: _mask({DeviceAction.logWater}),
      });
      final p = await SharedPreferences.getInstance();
      expect(p.getInt(_maskKey),
          _mask({DeviceAction.markMoment, DeviceAction.torch}));
      expect(p.getInt(_tripleKey), _mask({DeviceAction.markMoment}));
    });
  });

  group('the follow-up is switched on by a migration', () {
    test('on, stamped with the load instant, and persisted', () async {
      final before = DateTime.now();
      final s = await _boot({_maskKey: _mask({DeviceAction.logWater})});
      final after = DateTime.now();
      expect(s.followUpMoments, isTrue);
      final since = s.followUpMomentsSince!;
      expect(since.isBefore(before), isFalse);
      expect(since.isAfter(after), isFalse);
      final p = await SharedPreferences.getInstance();
      expect(p.getBool(_followKey), isTrue);
      expect(p.getInt(_sinceKey), since.millisecondsSinceEpoch);
    });

    test('a migration on any slot is enough', () async {
      final s = await _boot({_tripleKey: _mask({DeviceAction.logWater})});
      expect(s.followUpMoments, isTrue);
      expect(s.followUpMomentsSince, isNotNull);
    });

    test('an explicit "off" is switched on (those taps must be asked about)',
        () async {
      final s = await _boot({
        _maskKey: _mask({DeviceAction.logWater}),
        _followKey: false,
      });
      expect(s.followUpMoments, isTrue);
    });

    test('already on: its start is kept, not moved to now', () async {
      final at = DateTime(2026, 9, 1, 8);
      final s = await _boot({
        _maskKey: _mask({DeviceAction.logWater}),
        _followKey: true,
        _sinceKey: at.millisecondsSinceEpoch,
      });
      expect(s.followUpMoments, isTrue);
      expect(s.followUpMomentsSince, at);
    });

    test('NO log_water anywhere: the follow-up setting is left alone',
        () async {
      var s = await _boot({
        _maskKey: _mask({DeviceAction.markMoment, DeviceAction.torch}),
      });
      expect(s.followUpMoments, isFalse);
      expect(s.followUpMomentsSince, isNull);
      expect((await SharedPreferences.getInstance()).containsKey(_followKey),
          isFalse);

      s = await _boot({});
      expect(s.followUpMoments, isFalse);
    });
  });

  group('idempotent', () {
    test('a second load changes nothing, including the start', () async {
      final first = await _boot({
        _maskKey: _mask({DeviceAction.logWater, DeviceAction.torch}),
        _quadKey: _mask({DeviceAction.logWater}),
      });
      final since = first.followUpMomentsSince;
      final saved = await _stored();

      final second = await _boot(saved);
      expect(second.doubleTapActions,
          {DeviceAction.markMoment, DeviceAction.torch});
      expect(second.actionsForTaps(4), {DeviceAction.markMoment});
      expect(second.followUpMoments, isTrue);
      expect(second.followUpMomentsSince, since);
      expect(await _stored(), saved);
    });

    test('a user who switches the follow-up off afterwards keeps it off',
        () async {
      final first = await _boot({_maskKey: _mask({DeviceAction.logWater})});
      await first.setFollowUpMoments(false);
      final second = await _boot(await _stored());
      expect(second.followUpMoments, isFalse);
      expect(second.followUpMomentsSince, isNull);
      expect(second.doubleTapActions, {DeviceAction.markMoment});
    });

    test('a user who removes Mark a moment afterwards does not get it back',
        () async {
      final first = await _boot({_maskKey: _mask({DeviceAction.logWater})});
      await first.setDoubleTapActions({});
      final second = await _boot(await _stored());
      expect(second.doubleTapActions, isEmpty);
    });
  });
}
