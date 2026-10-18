// ECG features, round 2 (RED): "Keep waveform" off must not leave the raw
// recording behind on ANY path.
//
// The accepted-window packets (`ecg_reading_packet`) were already gated. But
// PREPARE also turned on the band's raw-save, and ordinary history sync then
// stores the band's raw R16 records in `ecg_raw_packet`: the waveform stayed
// durable with the preference off. Now the preference decides PREPARE too:
//   * a reading (persist: true) with Keep waveform OFF: PREPARE has no
//     raw-save member (rawSave: false); ON: it does;
//   * the choice is taken once, when the reading begins;
//   * the tap-counting gesture (persist: false) follows the same choice (owner
//     decision): off, its PREPARE has no raw-save member, so the band records
//     nothing and no gesture-tagged ecg_raw_packet rows are stored; on, the
//     packets are tagged as gesture contact as before;
//   * the CLEANUP list still switches raw-save OFF whatever PREPARE did.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ecg/ecg_models.dart';

import 'ecg_controller_features_test.dart' show FRig;

void main() {
  group('PREPARE follows Keep waveform', () {
    test('off (the default): PREPARE is asked for no raw save', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      expect(r.t.rawSaves, [false]);
    });

    test('on: PREPARE is asked for the raw save', () async {
      final r = FRig()..keep = true;
      await r.c.begin(EcgWrist.right);
      expect(r.t.rawSaves, [true]);
    });

    test('the retry after an inconclusive reading asks again with the choice '
        'of that moment', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      await r.record(1);
      await r.finishGood(seq: 50, result: 6);
      r.keep = true;
      await r.c.retry();
      expect(r.t.rawSaves, [false, true]);
    });

    test('switching it on after the reading began does not turn raw save on '
        'for that reading', () async {
      final r = FRig();
      await r.c.begin(EcgWrist.right);
      r.keep = true;
      await r.record(2);
      await r.finishGood();
      expect(r.t.rawSaves, [false]);
    });

    test('the tap-counting gesture follows the same choice: off, no raw '
        'save and so no gesture-tagged raw rows; on, today\'s behaviour',
        () async {
      for (final keep in [false, true]) {
        final r = FRig()..keep = keep;
        await r.c.begin(EcgWrist.right, persist: false);
        expect(r.t.rawSaves, [keep], reason: 'keep=$keep');
      }
    });
  });
}
