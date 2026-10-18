// One place decides what is shown, hidden or disabled. Every Feature
// is checked against every input that can move it, so a screen that asks
// `caps.of(Feature.x)` cannot disagree with a sibling that asks the same.

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/state/capabilities.dart';
import 'package:openstrap_edge/state/feature_flags.dart';

Capabilities _caps({
  TargetPlatform platform = TargetPlatform.android,
  String? generation,
  bool ecgPaired = false,
  bool ecgLive = false,
  bool connected = false,
  bool devMode = false,
  Set<FeatureFlag> flagsOff = const {},
  bool updateChecksBuild = false,
  bool healthShareBuild = false,
  bool healthShareConsent = false,
}) =>
    Capabilities(CapabilityInputs(
      platform: platform,
      generation: generation,
      ecgPaired: ecgPaired,
      ecgLive: ecgLive,
      connected: connected,
      devMode: devMode,
      flagsOff: flagsOff,
      updateChecksBuild: updateChecksBuild,
      healthShareBuild: healthShareBuild,
      healthShareConsent: healthShareConsent,
    ));

void main() {
  group('Availability', () {
    test('the three states and their reason', () {
      const a = Availability.available;
      const h = Availability.hidden;
      final d = Availability.disabled('why');
      expect(a.isAvailable, isTrue);
      expect(a.isHidden, isFalse);
      expect(a.isDisabled, isFalse);
      expect(h.isHidden, isTrue);
      expect(h.isAvailable, isFalse);
      expect(d.isDisabled, isTrue);
      expect(d.isAvailable, isFalse);
      expect(d.isHidden, isFalse);
      expect(d.reason, 'why');
      expect(a.reason, isNull);
      expect(h.reason, isNull);
      expect(Availability.disabled('x'), Availability.disabled('x'));
      expect(Availability.disabled('x'), isNot(Availability.disabled('y')));
    });

    test('a visible-and-enabled switch for a Disabled row is false', () {
      expect(Availability.disabled('r').isAvailable, isFalse);
      expect(Availability.disabled('r').isHidden, isFalse,
          reason: 'disabled is present, dimmed, inert: never hidden');
    });
  });

  group('every Feature is answered for any inputs', () {
    test('no Feature throws and none is missing from the matrix', () {
      final c = _caps();
      for (final f in Feature.values) {
        expect(c.of(f), isA<Availability>(), reason: '$f');
      }
    });
  });

  group('alarmSnooze', () {
    test('a 4.0 does not report how the alarm was stopped: disabled, with the '
        'reason, never hidden', () {
      final a = _caps(generation: 'gen4').of(Feature.alarmSnooze);
      expect(a.isDisabled, isTrue);
      expect(a.isHidden, isFalse);
      expect(a.reason, contains('WHOOP 5/MG'));
    });

    test('a 5/MG, and a band not identified yet, keep the rows', () {
      expect(_caps(generation: 'gen5').of(Feature.alarmSnooze),
          Availability.available);
      expect(_caps().of(Feature.alarmSnooze), Availability.available);
    });
  });

  group('developerMode', () {
    test('hidden unless dev mode is on', () {
      expect(_caps().of(Feature.developerMode), Availability.hidden);
      expect(_caps(devMode: true).of(Feature.developerMode),
          Availability.available);
    });
    test('independent of the band, platform and flags', () {
      for (final p in TargetPlatform.values) {
        expect(
            _caps(
                    devMode: true,
                    platform: p,
                    connected: true,
                    flagsOff: FeatureFlag.values.toSet())
                .of(Feature.developerMode),
            Availability.available);
      }
    });
  });

  group('relayEntry', () {
    test('Android with the flag on', () {
      expect(_caps().of(Feature.relayEntry), Availability.available);
    });
    test('hidden on every other platform', () {
      for (final p in TargetPlatform.values.where((p) => p != TargetPlatform.android)) {
        expect(_caps(platform: p).of(Feature.relayEntry), Availability.hidden,
            reason: '$p');
      }
    });
    test('hidden on Android when nativeRelay is off, like the relay itself', () {
      expect(
          _caps(flagsOff: {FeatureFlag.nativeRelay}).of(Feature.relayEntry),
          Availability.hidden);
    });
    test('other flags do not move it', () {
      expect(
          _caps(flagsOff: {
            FeatureFlag.tapClassifiers,
            FeatureFlag.naturalWake,
            FeatureFlag.sourceResolverUi,
            FeatureFlag.alertDispatcher,
          }).of(Feature.relayEntry),
          Availability.available);
    });
  });

  group('tap classifier flag', () {
    test('extraTapCounting and deviceLabTapTools follow tapClassifiers', () {
      for (final f in [Feature.extraTapCounting, Feature.deviceLabTapTools]) {
        expect(_caps().of(f), Availability.available, reason: '$f');
        expect(_caps(flagsOff: {FeatureFlag.tapClassifiers}).of(f),
            Availability.hidden,
            reason: '$f');
        expect(_caps(flagsOff: {FeatureFlag.nativeRelay}).of(f),
            Availability.available,
            reason: '$f');
      }
    });
  });

  group('ECG', () {
    test('ecgTouchTaps: available for a paired MG, else disabled with a reason',
        () {
      expect(_caps(ecgPaired: true).of(Feature.ecgTouchTaps),
          Availability.available);
      final none = _caps().of(Feature.ecgTouchTaps);
      expect(none.isDisabled, isTrue, reason: 'dimmed and inert, never hidden');
      expect(none.reason, 'This band has no ECG sensor');
    });
    test('ecgTouchTaps is about the remembered band, not the live link', () {
      expect(_caps(ecgPaired: true, connected: false).of(Feature.ecgTouchTaps),
          Availability.available);
      expect(_caps(ecgLive: true, connected: true).of(Feature.ecgTouchTaps).isDisabled,
          isTrue);
    });
    test('ecgEntry: shown only for a paired MG, hidden otherwise', () {
      expect(_caps(ecgPaired: true).of(Feature.ecgEntry),
          Availability.available);
      expect(_caps().of(Feature.ecgEntry), Availability.hidden);
      expect(_caps(ecgPaired: true, connected: false).of(Feature.ecgEntry),
          Availability.available,
          reason: 'stays while the band is away');
    });
    test('ecgTake needs a connected, live-identified MG', () {
      expect(_caps(connected: true, ecgLive: true).of(Feature.ecgTake),
          Availability.available);
      for (final c in [
        _caps(connected: true, ecgLive: false),
        _caps(connected: false, ecgLive: true),
        _caps(ecgPaired: true),
        _caps(),
      ]) {
        final a = c.of(Feature.ecgTake);
        expect(a.isDisabled, isTrue);
        expect(a.reason, 'Take ECG needs a connected WHOOP MG.');
      }
    });
  });

  group('source resolver flag', () {
    test('sourceCatalog and signalPriority follow sourceResolverUi', () {
      for (final f in [Feature.sourceCatalog, Feature.signalPriority]) {
        expect(_caps().of(f), Availability.available, reason: '$f');
        expect(_caps(flagsOff: {FeatureFlag.sourceResolverUi}).of(f),
            Availability.hidden,
            reason: '$f');
      }
    });
  });

  group('naturalWake', () {
    test('follows its flag only', () {
      expect(_caps().of(Feature.naturalWake), Availability.available);
      expect(_caps(flagsOff: {FeatureFlag.naturalWake}).of(Feature.naturalWake),
          Availability.hidden);
      expect(_caps(flagsOff: {FeatureFlag.tapClassifiers}).of(Feature.naturalWake),
          Availability.available);
    });
  });

  group('band family', () {
    test('bandAlerts: only the WHOOP families can be a destination', () {
      for (final g in ['gen4', 'gen5']) {
        expect(_caps(generation: g).of(Feature.bandAlerts),
            Availability.available,
            reason: g);
      }
      for (final g in [null, 'oura', 'ringconn', 'polar', '']) {
        expect(_caps(generation: g).of(Feature.bandAlerts), Availability.hidden,
            reason: '$g');
      }
    });
    test('bandAlertTargets is the registry answer', () {
      expect(_caps().bandAlertTargets, {'phone'});
      expect(_caps(generation: 'gen4').bandAlertTargets, {'phone', 'band'});
      expect(_caps(generation: 'gen5').bandAlertTargets, {'phone', 'band'});
    });
    test('hapticVocabulary and hapticProfile: only an MG has a measured profile',
        () {
      expect(_caps(generation: 'gen5').of(Feature.hapticVocabulary),
          Availability.available);
      expect(_caps(generation: 'gen5').hapticProfile, HapticDeviceProfile.whoopMg);
      for (final g in [null, 'gen4', 'oura']) {
        expect(_caps(generation: g).of(Feature.hapticVocabulary),
            Availability.hidden,
            reason: '$g');
        expect(_caps(generation: g).hapticProfile, isNull, reason: '$g');
      }
    });
  });

  group('connection-gated features are disabled, never hidden', () {
    final reasons = {
      Feature.alarmBandControls: 'The band is not connected',
      Feature.bandBuzz: 'Connect to the band first',
      Feature.breathingBeatTiming:
          'Needs the band on. The comparison uses beat timing.',
      Feature.bandRename: 'Connect to the band first',
    };
    for (final e in reasons.entries) {
      test('${e.key.name}: available on a live link, else disabled', () {
        expect(_caps(connected: true).of(e.key), Availability.available);
        final off = _caps().of(e.key);
        expect(off.isDisabled, isTrue);
        expect(off.isHidden, isFalse);
        expect(off.reason, e.value);
      });
      test('${e.key.name} does not depend on generation or platform', () {
        for (final g in [null, 'gen4', 'gen5']) {
          for (final p in TargetPlatform.values) {
            expect(_caps(connected: true, generation: g, platform: p).of(e.key),
                Availability.available);
            expect(_caps(generation: g, platform: p).of(e.key).isDisabled, isTrue);
          }
        }
      });
    }
  });

  group('build and consent gates', () {
    test('updateChecks follows the build switch', () {
      expect(_caps().of(Feature.updateChecks), Availability.hidden);
      expect(_caps(updateChecksBuild: true).of(Feature.updateChecks),
          Availability.available);
    });
    test('healthShare: the build has it OR the install already consented', () {
      expect(_caps().of(Feature.healthShare), Availability.hidden);
      expect(_caps(healthShareBuild: true).of(Feature.healthShare),
          Availability.available);
      expect(_caps(healthShareConsent: true).of(Feature.healthShare),
          Availability.available,
          reason: 'a consent that cannot be withdrawn is not consent');
      expect(
          _caps(healthShareBuild: true, healthShareConsent: true)
              .of(Feature.healthShare),
          Availability.available);
    });
  });

  group('androidAutomation', () {
    test('available on Android only', () {
      expect(_caps().of(Feature.androidAutomation), Availability.available);
      for (final p in TargetPlatform.values.where((p) => p != TargetPlatform.android)) {
        expect(_caps(platform: p).of(Feature.androidAutomation),
            Availability.hidden,
            reason: '$p');
      }
    });
  });

  group('phoneSteps', () {
    test('available on Android and iOS, disabled with a reason elsewhere', () {
      for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
        expect(_caps(platform: p).of(Feature.phoneSteps),
            Availability.available,
            reason: '$p');
      }
      for (final p in TargetPlatform.values.where(
          (p) => p != TargetPlatform.android && p != TargetPlatform.iOS)) {
        final a = _caps(platform: p).of(Feature.phoneSteps);
        expect(a.isDisabled, isTrue, reason: '$p is disabled, never hidden');
        expect(a.reason, 'This device cannot count steps');
      }
    });
  });

  group('inputs', () {
    test('equal inputs make equal capabilities, so a provider can skip notify',
        () {
      expect(_caps(connected: true), _caps(connected: true));
      expect(_caps(connected: true).hashCode, _caps(connected: true).hashCode);
      expect(_caps(connected: true), isNot(_caps()));
      expect(_caps(flagsOff: {FeatureFlag.naturalWake}),
          _caps(flagsOff: {FeatureFlag.naturalWake}));
      expect(_caps(flagsOff: {FeatureFlag.naturalWake}), isNot(_caps()));
    });
    test('detached inputs read the process-wide flags and nothing about a band',
        () {
      FeatureFlags.debugSet(FeatureFlag.tapClassifiers, false);
      addTearDown(FeatureFlags.resetForTest);
      final c = Capabilities(CapabilityInputs.detached(devMode: true));
      expect(c.of(Feature.extraTapCounting), Availability.hidden);
      expect(c.of(Feature.developerMode), Availability.available);
      expect(c.of(Feature.bandBuzz).isDisabled, isTrue);
      expect(c.of(Feature.ecgEntry), Availability.hidden);
    });
  });
}
