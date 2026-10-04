// 8V: the Device lab's kept ECG packets and the "Save lab log file" text.
// Pins the bound (360, oldest dropped), the session tag, that Clear empties the
// packets, that a probe's own result text lands in the session summary, and
// that the button saves the packets section (heading, format line, r17v1
// lines).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show LabradorR17;

import '../support/ecg_trace.dart';

final DateTime _t0 = DateTime(2026, 10, 2, 18, 17, 57, 367);

/// A packet whose first sample says which one it is.
LabradorR17 _pkt(int i, {List<int>? samples}) => r17(
  strapSeconds: 1790986679 + i,
  samples: samples ?? [i + 1, 2, 3, 4],
  flags: 0x0a,
  s2State: 1,
  progress: 3,
);

void main() {
  group('DeviceLabLog packets', () {
    test('at most 360 are kept and the oldest are dropped', () {
      final log = DeviceLabLog();
      expect(DeviceLabLog.maxPackets, 360);
      const total = 360 + 15;
      for (var i = 0; i < total; i++) {
        log.addPacket(_pkt(i), _t0.add(Duration(seconds: i)));
      }
      expect(log.packets, hasLength(360));
      // Oldest first: packets 0..14 fell off.
      expect(log.packets.first.strapSeconds, 1790986679 + 15);
      expect(log.packets.first.samples.first, 16);
      expect(log.packets.last.strapSeconds, 1790986679 + total - 1);
    });

    test('clear empties the packets along with everything else', () {
      final log = DeviceLabLog();
      log.addPacket(_pkt(0), _t0);
      log.addStep('a line', at: _t0);
      log.clear();
      expect(log.packets, isEmpty);
      expect(log.steps, isEmpty);
      expect(log.toPlainText(at: _t0), contains('No ECG packets yet.'));
    });

    test(
      'with no session the tag is "none"; an ECG session tags "tap <time>"',
      () {
        final log = DeviceLabLog();
        expect(log.sessionTag, 'none');
        log.addPacket(_pkt(0), _t0);
        expect(log.packets.single.tag, 'none');

        log.beginSession(
          method: 'ECG sensor touches',
          settings: 's',
          tapAt: _t0,
          at: _t0,
        );
        expect(log.sessionTag, 'tap 18:17:57.367');
        log.addPacket(_pkt(1), _t0);
        expect(log.packets.last.tag, 'tap 18:17:57.367');
      },
    );

    test('any other method tags with its own name and the tap time', () {
      final log = DeviceLabLog();
      log.beginSession(
        method: 'ECG touch probe',
        settings: 's',
        tapAt: _t0,
        at: _t0,
      );
      expect(log.sessionTag, 'ECG touch probe 18:17:57.367');
    });

    test('the tag stays after the session ends and goes on clear', () {
      final log = DeviceLabLog();
      log.beginSession(
        method: 'ECG sensor touches',
        settings: 's',
        tapAt: _t0,
        at: _t0,
      );
      log.endSession(count: 2, at: _t0.add(const Duration(seconds: 3)));
      expect(log.sessionTag, 'tap 18:17:57.367');
      log.clear();
      expect(log.sessionTag, 'none');
    });

    test('an explicit tag wins over the session tag', () {
      final log = DeviceLabLog();
      log.beginSession(
        method: 'ECG sensor touches',
        settings: 's',
        tapAt: _t0,
        at: _t0,
      );
      log.addPacket(_pkt(0), _t0, tag: 'probe 1');
      expect(log.packets.single.tag, 'probe 1');
    });

    test('a packet keeps what the band sent', () {
      final log = DeviceLabLog();
      log.addPacket(
        r17(
          strapSeconds: 1790986679,
          subseconds: 31785,
          samples: [5, -6, 7],
          flags: 0x0a,
          s2State: 1,
          progress: 3,
          quality: 2,
          unreadable: 0x10,
        ),
        _t0,
      );
      final p = log.packets.single;
      expect(p.strapSeconds, 1790986679);
      expect(p.subseconds, 31785);
      expect(p.flags, 0x0a);
      expect(p.s2State, 1);
      expect(p.progress, 3);
      expect(p.quality, 2);
      expect(p.unreadable, 0x10);
      expect(p.samples, [5, -6, 7]);
      expect(p.receivedAt, _t0);
    });
  });

  group('session result text', () {
    test('a probe result is the summary outcome, verbatim', () {
      final log = DeviceLabLog();
      log.beginSession(
        method: 'Buzz probe',
        settings: '3 trials',
        tapAt: _t0,
        at: _t0,
      );
      log.endSession(
        result: 'felt 2 of 3 buzzes',
        at: _t0.add(const Duration(milliseconds: 6400)),
      );
      expect(
        log.sessionSummaries.single,
        'Buzz probe | 3 trials | felt 2 of 3 buzzes | 6.4 s in total',
      );
      expect(
        log.steps.first,
        contains('Session ended: Buzz probe | 3 trials | felt 2 of 3 buzzes'),
      );
      expect(log.toPlainText(at: _t0), contains('felt 2 of 3 buzzes'));
    });

    test('a result wins over a count and a reason', () {
      final log = DeviceLabLog();
      log.beginSession(method: 'm', settings: 's', tapAt: _t0, at: _t0);
      log.endSession(count: 3, reason: 'x', result: 'custom', at: _t0);
      expect(log.sessionSummaries.single, startsWith('m | s | custom |'));
    });
  });

  group('the packets in the plain text', () {
    test(
      'heading, format line and one r17v1 line per packet, oldest first',
      () {
        final log = DeviceLabLog();
        log.addPacket(_pkt(0), _t0);
        log.addPacket(_pkt(1, samples: [0, 0, 0, 0]), _t0);
        final text = log.toPlainText(at: _t0);
        expect(text, contains('ECG packets, oldest first'));
        expect(text, contains('  format: $labPacketFormat'));
        final lines = text
            .split('\n')
            .where((l) => l.startsWith('  r17v1 '))
            .toList();
        expect(lines, hasLength(2));
        expect(lines.first, contains('sec=1790986679 '));
        expect(lines.last, contains('sec=1790986680 '));
        expect(lines.last, endsWith('b64=0'), reason: 'all-zero samples');
        expect(
          text.indexOf('Band events, oldest first'),
          lessThan(text.indexOf('ECG packets, oldest first')),
        );
      },
    );
  });

  group('Save lab log file on the screen', () {
    final saved = <String>[];

    testWidgets('saves the ECG packets section with the packets', (t) async {
      saved.clear();

      final lab = DeviceLabLog()
        ..addPacket(_pkt(0), _t0, tag: 'tap 18:17:57.367')
        ..addPacket(
          _pkt(1),
          _t0.add(const Duration(seconds: 1)),
          tag: 'tap 18:17:57.367',
        );

      t.view.physicalSize = const Size(1170, 12000);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: DeviceLabView(
            ecgSupported: true,
            packets: lab.packets,
            saveLog: (name, text) async {
              saved.add(text);
              return true;
            },
          ),
        ),
      );
      await t.pumpAndSettle();

      await t.tap(find.byKey(const ValueKey('lab-copy-all')));
      await t.pump();

      expect(saved, hasLength(1));
      final text = saved.single;
      expect(text, contains('ECG packets, oldest first'));
      expect(text, contains('  format:'));
      expect(text, contains('r17v1 tag=tap 18:17:57.367 | recv='));
      expect(
        RegExp(r'^  r17v1 ', multiLine: true).allMatches(text),
        hasLength(2),
      );
      expect(text, isNot(contains('No ECG packets yet.')));
    });
  });
}
