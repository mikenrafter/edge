// Sol round 1 on the haptics reorganisation: the widget-level findings.
//   1. the example's cancellation owner reaches the band and the phone, and
//      Stop / a newer start / dispose cancel it (the queue side is in
//      haptics_example_playback_test.dart)
//   4. section built-ins keep their action sheet (preview, edit, re-record,
//      reset) next to assigning
//   5. one confirmation policy for every built-in presented as a section preset
//   6. a band without a haptic vocabulary (a 4.0) gets no probe prompt
//   7. one availability rule for every preview: band connected OR phone on
//   8. the mini staff never runs into the preview button
//   9. the probe item opens the vocabulary probe, not the Device lab

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/haptics/example_playback.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/ui2/profile/haptics_settings.dart';
import 'package:openstrap_edge/ui2/profile/pattern_probe_page.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/haptics_reorg_support.dart';
import 'support/haptics_screen_support.dart';

Finder _k(String k) => find.byKey(ValueKey(k));

final _gPreset = presetPattern('sys.g', 'Gesture start default', 'gesture.start');
final _mine = userPattern('a', 'Morning nudge');
final _all = [_mine, _gPreset];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
  });
  setUp(() => Prefs.setString(kHapticsTabPref, ''));

  group('1. the example has one cancellation owner', () {
    late List<HapticCancel?> bandTokens, phoneTokens;
    late Completer<void> gate;
    setUp(() {
      bandTokens = [];
      phoneTokens = [];
      gate = Completer<void>();
    });

    Future<void> pumpEx(WidgetTester t, ReorgCalls c) => pumpReorg(t, c,
        patterns: _all,
        profile: kMg,
        phoneAlso: true,
        examplePlayer: (s) async {
          bandTokens.add(HapticCancel.current);
          await gate.future;
          return true;
        },
        phoneVibrate: (s) async {
          phoneTokens.add(HapticCancel.current);
        });

    testWidgets('band and phone both run under the example\'s token',
        (t) async {
      await pumpEx(t, ReorgCalls());
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:breathing'));
      await t.pump();
      expect(bandTokens.first, isNotNull, reason: 'no token reached the band');
      expect(phoneTokens.first, same(bandTokens.first));
      gate.complete();
      await t.pumpAndSettle();
    });

    testWidgets('Stop cancels the token', (t) async {
      await pumpEx(t, ReorgCalls());
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:breathing'));
      await t.pump();
      final tok = bandTokens.first;
      expect(tok?.cancelled, isFalse);
      await t.tap(_k('haptic-example-stop:breathing'));
      await t.pump();
      expect(tok, isNotNull);
      expect(tok!.cancelled, isTrue);
      gate.complete();
      await t.pumpAndSettle();
    });

    testWidgets('starting another example cancels the first', (t) async {
      await pumpEx(t, ReorgCalls());
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:breathing'));
      await t.pump();
      final first = bandTokens.first;
      await t.tap(_k('haptic-example-play:gestures'));
      await t.pump();
      expect(first, isNotNull);
      expect(first!.cancelled, isTrue);
      expect(bandTokens.last?.cancelled, isFalse);
      gate.complete();
      await t.pumpAndSettle();
    });

    testWidgets('leaving the page cancels it', (t) async {
      await pumpEx(t, ReorgCalls());
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-example-play:breathing'));
      await t.pump();
      final tok = bandTokens.first;
      await t.pumpWidget(const SizedBox());
      expect(tok, isNotNull);
      expect(tok!.cancelled, isTrue);
      gate.complete();
      await t.pumpAndSettle();
    });
  });

  group('4. section built-ins keep their actions', () {
    testWidgets('the row has an actions button: preview, use on a slot, edit '
        'notes, re-record, reset; no rename or delete', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-preset-actions:sys.g'));
      await t.pumpAndSettle();
      for (final k in [
        'haptic-action-preview',
        'haptic-action-assign',
        'haptic-action-edit',
        'haptic-action-rerecord',
        'haptic-action-reset',
      ]) {
        expect(_k(k), findsOneWidget, reason: k);
      }
      expect(_k('haptic-action-rename'), findsNothing);
      expect(_k('haptic-action-delete'), findsNothing);
      await t.tap(_k('haptic-action-preview'));
      await t.pumpAndSettle();
      expect(c.played, hasLength(1));
      await t.tap(_k('haptic-preset-actions:sys.g'));
      await t.pumpAndSettle();
      await t.tap(_k('haptic-action-reset'));
      await t.pumpAndSettle();
      expect(c.reset, ['sys.g']);
    });

    testWidgets('tapping the row itself still asks to assign', (t) async {
      await pumpReorg(t, ReorgCalls(), patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-preset:sys.g'));
      await t.pumpAndSettle();
      expect(_k('haptic-preset-confirm'), findsOneWidget);
    });
  });

  group('5. one confirmation policy for section presets', () {
    Future<void> viaPicker(WidgetTester t) async {
      await t.tap(_k('haptic-slot:gesture.followUp'));
      await t.pumpAndSettle();
      await t.tap(_k('pattern-picker-row:sys.g'));
      await t.pumpAndSettle();
    }

    testWidgets('picked from a slot\'s picker: cancel assigns nothing',
        (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await viaPicker(t);
      expect(_k('haptic-preset-confirm'), findsOneWidget);
      expect(c.assigned, isEmpty);
      await t.tap(find.descendant(
          of: _k('haptic-preset-confirm'), matching: find.text('Cancel')));
      await t.pumpAndSettle();
      expect(c.assigned, isEmpty);
    });

    testWidgets('picked from a slot\'s picker: confirm assigns to THAT slot',
        (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await viaPicker(t);
      await t.tap(_k('haptic-preset-confirm-ok'));
      await t.pumpAndSettle();
      expect(c.assigned, [('gesture.followUp', 'sys.g')]);
    });

    testWidgets('a user pattern still goes on at once', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-slot:gesture.followUp'));
      await t.pumpAndSettle();
      await t.tap(_k('pattern-picker-row:a'));
      await t.pumpAndSettle();
      expect(_k('haptic-preset-confirm'), findsNothing);
      expect(c.assigned, [('gesture.followUp', 'a')]);
    });

    testWidgets('"Use on a slot" asks too', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c, patterns: _all, profile: kMg);
      await openHapticsTab(t, 'cues');
      await t.tap(_k('haptic-preset-actions:sys.g'));
      await t.pumpAndSettle();
      await t.tap(_k('haptic-action-assign'));
      await t.pumpAndSettle();
      await t.tap(_k('haptic-assign-slot:gesture.followUp'));
      await t.pumpAndSettle();
      expect(_k('haptic-preset-confirm'), findsOneWidget);
      expect(c.assigned, isEmpty);
    });
  });

  group('6. the probe prompt needs a band that supports a vocabulary', () {
    testWidgets('a 4.0 (no vocabulary to measure): no prompt, and the probe '
        'cannot be opened', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c,
          patterns: _all, profile: null, vocabularySupported: false);
      await openSettingsTab(t);
      expect(_k('haptics-probe-prompt'), findsNothing);
      expect(_k('haptics-probe'), findsOneWidget, reason: 'always an item');
      await t.tap(_k('haptics-probe'));
      await t.pumpAndSettle();
      expect(c.probeOpened, 0);
    });

    testWidgets('a band that supports one but has none yet: the prompt',
        (t) async {
      await pumpReorg(t, ReorgCalls(),
          patterns: _all, profile: null, vocabularySupported: true);
      await openSettingsTab(t);
      expect(_k('haptics-probe-prompt'), findsOneWidget);
    });

    testWidgets('a band with its vocabulary: no prompt', (t) async {
      await pumpReorg(t, ReorgCalls(),
          patterns: _all, profile: kMg, vocabularySupported: true);
      await openSettingsTab(t);
      expect(_k('haptics-probe-prompt'), findsNothing);
    });
  });

  group('7. every preview shares one availability rule', () {
    Future<void> openSheet(WidgetTester t) async {
      await t.tap(_k('haptic-pattern:a'));
      await t.pumpAndSettle();
    }

    testWidgets('disconnected + phone on: a saved pattern previews on the '
        'phone', (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c,
          patterns: _all, profile: kMg, bandConnected: false, phoneAlso: true);
      await openSheet(t);
      await t.tap(_k('haptic-action-preview'));
      await t.pumpAndSettle();
      expect(c.phone, ['a']);
      expect(c.played, isEmpty);
    });

    testWidgets('disconnected + phone off: the preview is unavailable',
        (t) async {
      final c = ReorgCalls();
      await pumpReorg(t, c,
          patterns: _all, profile: kMg, bandConnected: false);
      await openSheet(t);
      await t.tap(_k('haptic-action-preview'));
      await t.pumpAndSettle();
      expect(c.phone, isEmpty);
      expect(c.played, isEmpty);
    });

    test('no preview entry point (picker, re-record, new from taps) asks '
        'for the band alone', () {
      final src = File('lib/ui2/profile/haptics_settings.dart')
          .readAsStringSync();
      expect('bandConnected: bandConnected,'.allMatches(src), isEmpty,
          reason: 'pass the shared availability (band OR phone) instead');
    });
  });

  group('8. the mini staff never meets the preview button', () {
    for (final w in [320.0, 360.0, 390.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('${w.toInt()} pt at ${scale}x', (t) async {
          t.view.physicalSize = Size(w, 4000);
          t.view.devicePixelRatio = 1;
          addTearDown(t.view.reset);
          final c = ReorgCalls();
          for (final tab in ['alerts', 'cues']) {
            await t.pumpWidget(MaterialApp(
              theme: buildTheme(Brightness.light),
              builder: (cx, child) => MediaQuery(
                data: MediaQuery.of(cx)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: reorgView(c,
                  patterns: _all,
                  profile: kMg,
                  initialTab:
                      HapticsTab.values.firstWhere((x) => x.id == tab)),
            ));
            await t.pumpAndSettle();
            expect(t.takeException(), isNull, reason: '$tab');
            final keys = withKeyPrefix(t, 'haptic-slot-staff:')
                .map((x) => (x.key as ValueKey<String>).value.substring(18));
            expect(keys, isNotEmpty);
            for (final k in keys) {
              final staff = t.getRect(_k('haptic-slot-staff:$k'));
              final btn = t.getRect(_k('haptic-slot-preview:$k'));
              expect(staff.right, lessThanOrEqualTo(btn.left),
                  reason: '$tab/$k: staff runs into the preview button');
              expect(staff.width, greaterThanOrEqualTo(96),
                  reason: '$tab/$k: staff too narrow to read');
            }
          }
        });
      }
    }
  });

  group('9. the probe item opens the vocabulary probe', () {
    test('the route does not send it to the Device lab', () {
      final src = File('lib/ui2/profile/haptics_settings.dart').readAsStringSync();
      final i = src.indexOf('onOpenProbe:');
      expect(i, greaterThan(0));
      final line = src.substring(i, src.indexOf('\n', i));
      expect(line, isNot(contains('DeviceLab')));
    });

    testWidgets('the launcher opens the probe page on a connected MG',
        (t) async {
      final lab = DeviceLabLog();
      final r = HardwareProbeRunner(
        lab: lab,
        sendBuzz: (onReply) async => true,
        sendPattern: (e, l, onReply) async => true,
        isConnected: () => true,
        ecgSupported: () => true,
        ecgBusy: () => false,
        beginEcg: () async => false,
        endEcg: () async {},
        isEcgAlive: () => false,
      );
      t.view.physicalSize = const Size(1170, 2532);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: PatternProbeLauncher(runner: r, logText: () => 'log'),
      ));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byType(PatternProbePage), findsOneWidget);
      expect(r.pattern, isNotNull);
      // Finishing closes the probe on the runner; the page must stay, as its
      // end screen, with the summary and the way to save the log.
      await t.tap(find.byKey(const ValueKey('pattern-finish')));
      await t.pump(const Duration(milliseconds: 300));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('pattern-end')), findsOneWidget);
      expect(find.byKey(const ValueKey('pattern-copy')), findsOneWidget);
      expect(find.text('Opening the probe…'), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    });
  });
}
