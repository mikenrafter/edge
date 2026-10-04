// 8AI.3 (red): the "Gesture alert" setting is gone.
//
// It was a haptic slot ('alert.gesture') that held a pattern (default: Four
// pulses) in the stored 'gesture' alert rule. Nothing ever played it: gesture
// buzzes go out under the constant rules kEcgTapRule and kGestureAckRule and
// the three gesture cues (start, follow-up, confirm), none of which read the
// stored rule. The rule's enabled flag gates nothing either (the dispatcher
// is handed the constant rule), so removing the slot changes no delivery.
//
// The stored 'gesture' rule stays in the registry (its order is frozen, and
// old stored data must keep decoding); only the slot, its row and its default
// preset go.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/tap_ack.dart';
import 'package:openstrap_edge/haptics/builtin_patterns.dart';
import 'package:openstrap_edge/haptics/haptic_slots.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/notify/notification_prefs.dart';

import '../phase8/support/dart_source.dart';
import 'support/g45_support.dart';

/// Prefs whose stored 'gesture' rule is switched OFF with no destination: the
/// strictest old data a wearer could have.
NotificationPrefs _gestureRuleOff() {
  const prefs = NotificationPrefs();
  return prefs.withAlertRule({
    ...prefs.alertRule('gesture').toJson(),
    'enabled': false,
    'destinations': 0,
  });
}

AlertDispatcher _dispatcher() => AlertDispatcher(
      phone: () async => false,
      band: () async => true,
      isConnected: () => true,
      supportedBandModes: const {AlertExecutionMode.phoneLive},
      ledger: MemoryAlertDeliveryLedger(),
    );

void main() {
  group('the slot is gone', () {
    test('the Gestures section lists the four cues and nothing else', () {
      final gestures =
          kHapticSlotSections.firstWhere((s) => s.id == 'gestures');
      // 8AK added "Gesture failed" as the fourth cue.
      expect([for (final s in gestures.slots) s.key], [
        kGestureStartKey,
        kGestureFollowUpKey,
        kGestureConfirmKey,
        kGestureFailedKey,
      ]);
    });

    test('no slot anywhere is alert.gesture', () {
      final keys = [
        for (final s in kHapticSlotSections) ...[for (final x in s.slots) x.key],
      ];
      expect(keys, isNot(contains('alert.gesture')));
    });

    test('no slot is labelled "Gesture alert"', () {
      final labels = [
        for (final s in kHapticSlotSections) ...[for (final x in s.slots) x.label],
      ];
      expect(labels, isNot(contains('Gesture alert')));
    });

    test('alert.gesture has no default preset and no built-in', () {
      expect(alertPresetKey('alert.gesture'), isNull);
      expect(builtInDefault('alert.gesture'), isNull);
    });

    testWidgets('the Haptics screen shows no Gesture alert row', (t) async {
      await pumpHub(t, HubCalls());
      await openHapticsTab(t, 'alerts');
      expect(find.text('Gesture alert'), findsNothing);
      expect(find.byKey(const ValueKey('haptic-slot:alert.gesture')),
          findsNothing);
      // The gesture cues are on the Cues tab.
      await openHapticsTab(t, 'cues');
      expect(find.text('Gesture alert'), findsNothing);
      expect(find.byKey(const ValueKey('haptic-slot:alert.gesture')),
          findsNothing);
      expect(find.byKey(const ValueKey('haptic-slot:gesture.confirm')),
          findsOneWidget);
    });
  });

  group('old stored data is safe', () {
    test('the stored gesture rule still decodes and reads back', () {
      final prefs = _gestureRuleOff();
      final rule = prefs.alertRule('gesture');
      expect(rule.enabled, isFalse);
      expect(NotificationPrefs.alertRuleOrder, contains('gesture'),
          reason: 'the registry order is frozen');
    });

    test('a leftover alert.gesture slot key labels without throwing', () {
      final label = slotPatternLabel(
        'alert.gesture',
        patterns: const [],
        alerts: _gestureRuleOff(),
        channels: const {},
        cueAssignments: const {},
      );
      expect(label, isA<String>());
    });

    test('a leftover alert.gesture key in the cue assignments is ignored', () {
      final m = decodeCueAssignments(
          '{"alert.gesture":"x","gesture.confirm":"y"}');
      expect(m, {'gesture.confirm': 'y'});
    });
  });

  group('the rule\'s enabled flag gated nothing: delivery is unchanged', () {
    test('a gesture count cue is delivered with the stored rule switched off',
        () {
      fakeAsync((async) {
        // The stored rule is never an input of the dispatch: the constant is.
        final prefs = _gestureRuleOff();
        expect(prefs.alertRule('gesture').enabled, isFalse);
        AlertDeliveryOutcome? out;
        _dispatcher()
            .dispatch(
              kEcgTapRule,
              eventId: 'g8:ecg:1',
              sourceTime: DateTime.now(),
              historical: false,
              bandDelivery: () async => BuzzDelivery.complete,
            )
            .then((o) => out = o);
        async.elapse(const Duration(seconds: 10));
        expect(out?.targets, ['band']);
      });
    });

    test('the confirm ack is delivered with the stored rule switched off', () {
      fakeAsync((async) {
        expect(_gestureRuleOff().alertRule('gesture').enabled, isFalse);
        AlertDeliveryOutcome? out;
        _dispatcher()
            .dispatch(
              kGestureAckRule,
              eventId: 'g8:ack',
              sourceTime: DateTime.now(),
              historical: false,
              bandDelivery: () async => BuzzDelivery.complete,
            )
            .then((o) => out = o);
        async.elapse(const Duration(seconds: 10));
        expect(out?.targets, ['band']);
      });
    });

    test('nothing in lib reads the stored gesture rule to decide a buzz', () {
      final hits = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final code = codeOnly(f.readAsStringSync());
        if (RegExp(r'''alertRule\(\s*['"]gesture['"]''').hasMatch(code) ||
            RegExp(r'''alertRules\[\s*['"]gesture['"]''').hasMatch(code)) {
          hits.add(f.path);
        }
      }
      expect(hits, isEmpty);
    });
  });
}
