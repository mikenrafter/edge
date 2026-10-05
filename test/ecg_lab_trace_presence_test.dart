// 8AN phase A (measure; no behaviour change): one lab capture must give the
// band's presence debounce. So the session's trace
//  * says presence and the unreadable reasons on every packet line (already
//    true; pinned here), and
//  * logs each presence transition and each sample-contact transition with the
//    milliseconds since the tap, so "sample contact on" -> "presence on" (and
//    the lift) can be read off a single log, and
//  * the Device lab's "ECG packets" export keeps flags/unreadable so a packet
//    with presence set round-trips into test/support/ecg_trace.dart.
//
// Kept after ECG Fast mode was retired (Oct 4): these lines belong to the one
// ECG path. Trace wording (EcgTapSession `step`):
//   'Presence on, <ms> ms after the tap.'      / 'Presence off, <ms> ms ...'
//   'Sample contact on, <ms> ms after the tap.' / 'Sample contact off, <ms> ms ...'
// One line per CHANGE (the state before the first packet is "off"); a packet
// that repeats the state logs nothing. "Sample contact" is whether the packet
// has any sample with contact (ecgContactMask).

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/ecg_tap_counter.dart';
import 'package:openstrap_edge/gestures/ecg_tap_session.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';

import 'support/ecg_trace.dart';
import 'support/ecg_presence_packets.dart';

final _presence = RegExp(r'^Presence (on|off), (\d+) ms after the tap');
final _contact = RegExp(r'^Sample contact (on|off), (\d+) ms after the tap');

List<String> _lines(List<String> steps, RegExp re) =>
    [for (final s in steps) if (re.hasMatch(s)) s];

/// An EcgTapSession (existing API only) on a virtual clock.
class _Rig {
  _Rig(EcgTapThresholds th) {
    session = EcgTapSession(
      beginStream: () async => true,
      endStream: () async {},
      isStreamAlive: () => true,
      buzz: (pulses, id) async => true,
      maxTaps: () => 5,
      thresholds: () => th,
      onFinished: (c, r) {},
      step: steps.add,
      now: () => now,
      wait: (_) async {},
      pollEvery: const Duration(hours: 1),
    );
  }

  late final EcgTapSession session;
  final steps = <String>[];
  DateTime now = t0;

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> begin() async {
    now = t0.add(const Duration(milliseconds: 300));
    await session.start(tapAt());
    await settle();
  }

  /// A packet ending at strap second [sec], received 2.8 s after the tap plus
  /// one second per second of strap time after 1000.
  Future<void> feed(int sec,
      {bool presence = false, bool contact = false, int unreadable = 0}) async {
    now = t0.add(Duration(milliseconds: 2800 + (sec - 1000) * 1000));
    session.onFrame(presencePacket(sec,
        presence: presence, contact: contact, unreadable: unreadable));
    await settle();
  }
}

void main() {
  group('the session trace', () {
    // Wide windows so the gesture is still running on the last packet.
    final wide = EcgTapThresholds(startMs: 1100, confirmMs: 1000);

    test('presence and sample-contact transitions carry the ms since the '
        'tap', () async {
      final r = _Rig(wide);
      await r.begin();
      // Tap received at +300 ms; packets at +2800, +3800, +4800, +5800.
      await r.feed(1000); // nothing yet
      await r.feed(1001, presence: true, contact: true);
      await r.feed(1002, presence: true, contact: true); // no change
      await r.feed(1003); // both off again
      final presence = _lines(r.steps, _presence);
      final contact = _lines(r.steps, _contact);
      expect(presence, hasLength(2), reason: r.steps.join('\n'));
      expect(contact, hasLength(2), reason: r.steps.join('\n'));
      expect(presence[0], startsWith('Presence on, 3500 ms after the tap'));
      expect(contact[0], startsWith('Sample contact on, 3500 ms after the tap'));
      expect(presence[1], startsWith('Presence off, 5500 ms after the tap'));
      expect(contact[1],
          startsWith('Sample contact off, 5500 ms after the tap'));
    });

    test('presence can lead or trail the samples: each is logged on its own',
        () async {
      final r = _Rig(wide);
      await r.begin();
      await r.feed(1000);
      await r.feed(1001, contact: true); // samples first
      await r.feed(1002, contact: true, presence: true); // band catches up
      expect(_lines(r.steps, _contact), hasLength(1));
      expect(_lines(r.steps, _presence), hasLength(1));
      expect(_lines(r.steps, _contact).single, contains('3500 ms'));
      expect(_lines(r.steps, _presence).single, contains('4500 ms'));
    });

    test('a packet line says presence and the unreadable reasons', () async {
      final r = _Rig(wide);
      await r.begin();
      await r.feed(1000, presence: true, unreadable: 0x03);
      final line = r.steps.firstWhere((s) => s.startsWith('Packet 1:'));
      expect(line, contains('presence on'));
      expect(line, contains('unreadable low_amplitude+significant_noise'));
    });
  });

  group('the lab export', () {
    test('a packet with flags 0x08 and an unreadable mask round-trips through '
        'the export into the trace parser', () {
      final src = r17(
        strapSeconds: 1790986679,
        subseconds: 31785,
        samples: List.generate(100, (i) => i.isEven ? 120 : -120),
        flags: 0x08,
        s2State: 1,
        progress: 3,
        quality: 2,
        unreadable: 0x05,
      );
      expect(src.presence, isTrue);
      final at = DateTime.fromMillisecondsSinceEpoch(1790986679251);
      final text = labLogText(
        entries: const [],
        steps: const [],
        sessions: const [],
        packets: [LabPacket.of(src, at, 'tap 18:17:57.367')],
        at: at,
      );
      final back = Trace.parse(text).packets.single;
      expect(back.tag, 'tap 18:17:57.367');
      expect(back.receivedAt, at);
      expect(back.r.presence, isTrue);
      expect(back.r.flags.raw, 0x08);
      expect(back.r.unreadable.raw, 0x05);
      expect(back.r.s2State, 1);
      expect(back.r.samples, src.samples);
    });

    test('a packet without presence keeps presence off through the export',
        () {
      final src = r17(strapSeconds: 5, samples: List.filled(100, 0));
      final line = labPacketLine(LabPacket.of(src, DateTime.utc(2026), 't'));
      final back = Trace.parse(line).packets.single;
      expect(back.r.presence, isFalse);
      expect(line, contains('flags=00'));
    });
  });
}
