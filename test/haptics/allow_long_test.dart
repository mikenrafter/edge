// 8AD (B) — the "allow long sequences" setting.
//
// Off (the default) the 10 s runtime cap of 8AC holds; on, it is lifted
// everywhere it applies: the tap editor, the notes editor, and the compile at
// delivery (HapticsService.deliver). What still holds either way: the
// 8-command plan cap, the band queue and the 30-per-2-min ledger.
//
// API chosen for this phase:
//
//   Prefs.hapticsAllowLong        const String 'haptics_allow_long_sequences'
//   Prefs.allowLongHaptics        static bool getter, default false (the
//                                 "synchronous Prefs helper" read)
//   maxRuntimeFor({required bool allowLong}) in haptic_compiler.dart:
//                                 null when allowLong, else kMaxHapticRuntime
//   Duration? maxRuntime          new NAMED parameter (default
//                                 kMaxHapticRuntime, null lifts the cap) on
//                                 deliverBandSequence, bandSequenceTimeout,
//                                 bandSequenceCommands and bandSequenceSettle
//                                 in haptic_player.dart. planForTaps and
//                                 compile(maxRuntimeMs:) already take it.
//   AppState passes `maxRuntime: maxRuntimeFor(allowLong: Prefs.allowLongHaptics)`
//   at EVERY call of those four functions.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_player.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phase8/support/dart_source.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

/// Eight 500 ms taps 1.5 s apart: 14.5 s, over the 10 s cap, and exactly
/// 8 commands when compiled (planForTaps with the cap lifted gives 16.25 s
/// felt).
BuzzSequence _longTaps() => BuzzSequence(
  [for (var i = 0; i < 8; i++) i * 2000],
  durationsMs: List.filled(8, 500),
);

/// A short rhythm, well inside the cap.
BuzzSequence _shortTaps() => BuzzSequence([0, 500, 1000]);

String _sixNotes() =>
    'N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff R12 N4ff'; // 11.75 s felt

String _tenNotes() => List.filled(10, 'N4ff').join(' R12 ');

/// One tap, with notes (no baked plan) over the cap: with the cap on the
/// notes are not compiled, so delivery falls back to the one tap (1 command);
/// with it lifted the notes play (6 commands).
BuzzSequence _notesRule(String notes) => BuzzSequence(
  [0],
  notes: notes,
  profileId: _mg.id,
  profileVersion: _mg.version,
);

class _Band {
  final writes = <String>[];
  final buzzes = <int>[];

  Future<bool> write(List<int> effects, int loop) async {
    writes.add('$effects x$loop');
    return true;
  }

  Future<bool> buzz() async {
    buzzes.add(0);
    return true;
  }

  Future<bool> buzzFor(int ms) async {
    buzzes.add(ms);
    return true;
  }

  Future<bool> ended(Duration t) async => true;
}

BuzzDelivery? _deliver(
  FakeAsync async,
  _Band band,
  BuzzSequence s, {
  required bool lifted,
}) {
  BuzzDelivery? out;
  deliverBandSequence(
    s,
    profile: _mg,
    buzz: band.buzz,
    buzzForDuration: band.buzzFor,
    writePattern: band.write,
    waitEnded: band.ended,
    isConnected: () => true,
    maxRuntime: lifted ? null : kMaxHapticRuntime,
  ).then((v) => out = v);
  async.elapse(const Duration(minutes: 5));
  return out;
}

void main() {
  group('the setting', () {
    // First on purpose: Prefs caches its SharedPreferences instance.
    test('the key is haptics_allow_long_sequences and it defaults to off',
        () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs.ensureLoaded();
      expect(Prefs.hapticsAllowLong, 'haptics_allow_long_sequences');
      expect(Prefs.allowLongHaptics, isFalse);
    });

    test('turning it on and off is read back at once', () async {
      await Prefs.ensureLoaded();
      Prefs.setBool(Prefs.hapticsAllowLong, true);
      expect(Prefs.allowLongHaptics, isTrue);
      Prefs.setBool(Prefs.hapticsAllowLong, false);
      expect(Prefs.allowLongHaptics, isFalse);
    });

    test('it is stored under the key as a bool', () async {
      await Prefs.ensureLoaded();
      Prefs.setBool(Prefs.hapticsAllowLong, true);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('haptics_allow_long_sequences'), isTrue);
      Prefs.setBool(Prefs.hapticsAllowLong, false);
    });

    test('maxRuntimeFor: the 10 s cap when off, none when on', () {
      expect(maxRuntimeFor(allowLong: false), kMaxHapticRuntime);
      expect(maxRuntimeFor(allowLong: false), const Duration(seconds: 10));
      expect(maxRuntimeFor(allowLong: true), isNull);
    });
  });

  group('planForTaps', () {
    test('over 10 s: no plan with the cap, a plan without it', () {
      expect(planForTaps(_longTaps(), _mg), isNull);
      final plan = planForTaps(_longTaps(), _mg, maxRuntime: null);
      expect(plan, isNotNull);
      expect(plan!.runtimeMs, greaterThan(10000));
    });

    test('a rhythm inside the cap compiles the same either way', () {
      final capped = planForTaps(_shortTaps(), _mg)!;
      final lifted = planForTaps(_shortTaps(), _mg, maxRuntime: null)!;
      expect(lifted.steps.length, capped.steps.length);
      expect(lifted.runtimeMs, capped.runtimeMs);
      expect(lifted.summary, capped.summary);
    });

    test('maxRuntimeFor feeds it', () {
      expect(planForTaps(_longTaps(), _mg,
          maxRuntime: maxRuntimeFor(allowLong: false)), isNull);
      expect(planForTaps(_longTaps(), _mg,
          maxRuntime: maxRuntimeFor(allowLong: true)), isNotNull);
    });
  });

  group('compile', () {
    final notes = PatternTranscript.parseCode(_sixNotes()).entries;

    test('notes over 10 s: null with the cap, a plan without', () {
      expect(
        compile(notes, _mg, extended: false,
            maxRuntimeMs: kMaxHapticRuntime.inMilliseconds),
        isNull,
      );
      final plan = compile(notes, _mg, extended: false, maxRuntimeMs: null);
      expect(plan, isNotNull);
      expect(plan!.runtimeMs, greaterThan(10000));
      expect(plan.steps, hasLength(6));
    });

    test('the 8-command cap still holds with the runtime cap lifted', () {
      final ten = PatternTranscript.parseCode(_tenNotes()).entries;
      final plan = compile(ten, _mg, extended: false, maxRuntimeMs: null);
      expect(plan, isNotNull);
      expect(plan!.steps.length, lessThanOrEqualTo(8));
      expect(plan.exact, isFalse);
    });
  });

  group('the delivery seam', () {
    test('notes over the cap: 1 command with it, 6 when lifted', () {
      final s = _notesRule(_sixNotes());
      expect(bandSequenceCommands(s, _mg), 1);
      expect(
        bandSequenceCommands(s, _mg, maxRuntime: kMaxHapticRuntime),
        1,
      );
      expect(bandSequenceCommands(s, _mg, maxRuntime: null), 6);
    });

    test('bandSequenceTimeout grows to cover the long plan', () {
      final s = _notesRule(_sixNotes());
      final capped = bandSequenceTimeout(s, _mg);
      final lifted = bandSequenceTimeout(s, _mg, maxRuntime: null);
      expect(capped, lessThan(const Duration(seconds: 10)));
      // felt 11.75 s + 2 s per command (6) + 1 s.
      expect(lifted, greaterThanOrEqualTo(const Duration(seconds: 24)));
      expect(lifted, greaterThan(capped));
    });

    test('bandSequenceSettle follows the same plan', () {
      final s = _notesRule(_sixNotes());
      expect(bandSequenceSettle(s, _mg, maxRuntime: null),
          greaterThan(Duration.zero));
      expect(bandSequenceSettle(s, _mg), greaterThan(Duration.zero));
    });

    test('the same rhythm inside the cap is delivered identically', () {
      final s = BuzzSequence(
        [0],
        notes: 'N4ff R4 N4ff',
        profileId: _mg.id,
        profileVersion: _mg.version,
      );
      expect(bandSequenceCommands(s, _mg, maxRuntime: null),
          bandSequenceCommands(s, _mg));
      expect(bandSequenceTimeout(s, _mg, maxRuntime: null),
          bandSequenceTimeout(s, _mg));
    });

    test('delivery with the cap on plays the fallback; lifted plays the notes',
        () {
      fakeAsync((async) {
        final off = _Band();
        expect(
          _deliver(async, off, _notesRule(_sixNotes()), lifted: false),
          BuzzDelivery.complete,
        );
        expect(off.writes, hasLength(1));

        final on = _Band();
        expect(
          _deliver(async, on, _notesRule(_sixNotes()), lifted: true),
          BuzzDelivery.complete,
        );
        expect(on.writes, hasLength(6));
        expect(on.buzzes, isEmpty);
      });
    });

    test('long taps: per-tap buzzes with the cap on, compiled commands lifted',
        () {
      fakeAsync((async) {
        final off = _Band();
        expect(_deliver(async, off, _longTaps(), lifted: false),
            BuzzDelivery.complete);
        expect(off.writes, isEmpty);
        expect(off.buzzes, hasLength(8));

        final on = _Band();
        expect(_deliver(async, on, _longTaps(), lifted: true),
            BuzzDelivery.complete);
        expect(on.buzzes, isEmpty);
        expect(on.writes, isNotEmpty);
        expect(on.writes.length, lessThanOrEqualTo(8));
      });
    });

    test('the 8-command cap holds at delivery with the runtime cap lifted',
        () {
      final s = _notesRule(_tenNotes());
      expect(bandSequenceCommands(s, _mg, maxRuntime: null),
          inInclusiveRange(2, 8));
      fakeAsync((async) {
        final band = _Band();
        expect(_deliver(async, band, s, lifted: true), BuzzDelivery.complete);
        expect(band.writes.length, inInclusiveRange(2, 8));
      });
    });

    test('a short rhythm is delivered the same with the setting on or off',
        () {
      fakeAsync((async) {
        final off = _Band();
        final on = _Band();
        _deliver(async, off, _shortTaps(), lifted: false);
        _deliver(async, on, _shortTaps(), lifted: true);
        expect(on.writes, off.writes);
        expect(on.buzzes, off.buzzes);
      });
    });
  });

  group('wiring (source)', () {
    final src = File('lib/state/app_state.dart').readAsStringSync();
    final code = codeOnly(src);

    // 8AE.5: the delivery moved into HapticsService. That a delivery and its
    // timeout follow the setting is pinned by behaviour in
    // haptics_service_test.dart ('allow-long is read when a delivery
    // happens'); what stays here is where the setting comes from and that no
    // second path computes a plan's runtime.
    test('AppState hands the service the Prefs setting', () {
      final start = code.indexOf('late final HapticsService haptics');
      final ctor = code.substring(start, code.indexOf(');', start));
      expect(ctor, contains('allowLong: () => Prefs.allowLongHaptics'));
    });

    test('the service reads the setting through maxRuntimeFor, at every '
        'delivery', () {
      final svc = codeOnly(
          File('lib/haptics/haptics_service.dart').readAsStringSync());
      expect(svc, contains('maxRuntimeFor(allowLong: _allowLong())'));
    });

    for (final fn in [
      'deliverBandSequenceQueued',
      'bandSequenceTimeout',
    ]) {
      test('$fn is called from the service only (one source, AGENTS.md 4.7)',
          () {
        final offenders = <String>[];
        for (final f in dartFilesIn('lib')) {
          if (f.path.endsWith('lib/haptics/haptic_player.dart') ||
              f.path.endsWith('lib/haptics/haptics_service.dart')) {
            continue;
          }
          final c = codeOnly(f.readAsStringSync());
          for (final m in RegExp('(?<![A-Za-z_])$fn\\(').allMatches(c)) {
            offenders.add('${f.path}:${lineOf(c, m.start)}');
          }
        }
        expect(offenders, isEmpty, reason: offenders.join('\n'));
      });
    }

    test('the tap editor does not hard-code the cap in planForTaps', () {
      final ed = File('lib/ui2/profile/buzz_pattern.dart').readAsStringSync();
      final c = codeOnly(ed);
      final calls = RegExp(r'(?<![A-Za-z_])planForTaps\(').allMatches(c);
      expect(calls, isNotEmpty);
      for (final m in calls) {
        final close = closingOf(c, m.end - 1);
        expect(c.substring(m.end - 1, close + 1), contains('maxRuntime'),
            reason: 'planForTaps in buzz_pattern.dart must honor '
                'allow-long');
      }
    });
  });
}
