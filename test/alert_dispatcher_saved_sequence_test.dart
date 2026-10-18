import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const _base = AlertRule(
  id: 'water',
  kind: 'water',
  destinations: AlertRule.band,
  executionMode: AlertExecutionMode.phoneLive,
  staleAfter: Duration(seconds: 60),
  channelPolicyId: 'water',
);

AlertDispatcher _dispatcher({
  required Future<bool> Function(BuzzSequence) sequence,
  required Future<bool> Function() band,
  bool Function()? connected,
  Future<bool> Function()? phone,
}) =>
    Function.apply(AlertDispatcher.new, [], {
          #phone: phone ?? () async => true,
          #band: band,
          #bandSequence: sequence,
          #isConnected: connected ?? () => true,
          #ledger: MemoryAlertDeliveryLedger(),
        })
        as AlertDispatcher;

Future<AlertDeliveryOutcome> _deliver(
  AlertDispatcher d,
  AlertRule rule,
  String id, {
  Future<bool> Function()? override,
}) => d.dispatch(
  rule,
  eventId: id,
  sourceTime: DateTime.now(),
  historical: false,
  bandTransport: override,
);

void main() {
  test(
    'saved duration sequence replaces the fixed buzz once and respects connection gating',
    () async {
      final saved = BuzzSequence.fromJson({
        'offsetsMs': [0, 900],
        'durationsMs': [750, 80],
      });
      final rule = AlertRule.fromJson({
        ..._base.toJson(),
        'buzzSequence': saved.toJson(),
      });
      final played = <BuzzSequence>[];
      var fixed = 0;
      var connected = true;
      final d = _dispatcher(
        sequence: (s) async {
          played.add(s);
          return true;
        },
        band: () async {
          fixed++;
          return true;
        },
        connected: () => connected,
      );
      expect((await _deliver(d, rule, 'water:1')).targets, ['band']);
      expect((await _deliver(d, rule, 'water:1')).targets, isEmpty);
      expect(played, [saved]);
      expect(fixed, 0);
      connected = false;
      expect((await _deliver(d, rule, 'water:2')).targets, isEmpty);
      expect(played, [saved]);
      connected = true;
      expect((await _deliver(d, rule, 'water:2')).targets, ['band']);
      expect(played, [
        saved,
        saved,
      ], reason: 'a suppressed delivery never consumes its claim');
    },
  );

  test(
    'explicit band transport wins and absent sequences keep the fixed buzz',
    () async {
      var sequences = 0, fixed = 0, overrides = 0, phone = 0;
      final d = _dispatcher(
        sequence: (_) async {
          sequences++;
          return true;
        },
        band: () async {
          fixed++;
          return true;
        },
        phone: () async {
          phone++;
          return true;
        },
      );
      final chosen = _base.copyWith(buzzSequence: BuzzSequence([0, 300]));
      await _deliver(
        d,
        chosen,
        'override',
        override: () async {
          overrides++;
          return true;
        },
      );
      await _deliver(d, _base, 'legacy');
      await _deliver(
        d,
        chosen.copyWith(destinations: AlertRule.phone),
        'phone',
      );
      expect(overrides, 1);
      expect(fixed, 1);
      expect(phone, 1);
      expect(sequences, 0);
    },
  );

  test(
    'implicit saved sequence receives its own timeout above ten seconds',
    () {
      fakeAsync((async) {
        final saved = BuzzSequence([for (var i = 0; i < 8; i++) i * 2000]);
        var fixed = 0;
        final d = _dispatcher(
          sequence: (s) => playBuzzSequence(
            s,
            buzz: () async => true,
            isConnected: () => true,
          ),
          band: () async {
            fixed++;
            return true;
          },
        );
        AlertDeliveryOutcome? result;
        _deliver(
          d,
          _base.copyWith(buzzSequence: saved),
          'long',
        ).then((out) => result = out);
        async.elapse(const Duration(seconds: 11));
        expect(result, isNull, reason: 'the recorded rhythm is still playing');
        async.elapse(const Duration(seconds: 9));
        expect(result?.targets, ['band']);
        expect(result?.suppressionReason, isNull);
        expect(fixed, 0);
      });
    },
  );

  test('AppState supplies the shared dispatcher sequence transport', () {
    final source = File('lib/state/app_state.dart').readAsStringSync();
    final start = source.indexOf(
      'late final AlertDispatcher alertDispatcher =',
    );
    final end = source.indexOf('AlertDispatcher debugAlertDispatcher', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    expect(source.substring(start, end), contains('bandSequence:'));
  });
}
