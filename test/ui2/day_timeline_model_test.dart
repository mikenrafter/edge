// Pilot day-timeline, spec Tests §1 (geometry), §2 (the pure halves of the
// interaction rules) and §5 (stage wave). The rules live in
// lib/ui2/day_timeline/timeline_model.dart; the widget tests check that the
// chart draws and obeys them.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/charts.dart' show SleepStage;
import 'package:openstrap_edge/ui2/day_timeline/preview_stager.dart';
import 'package:openstrap_edge/ui2/day_timeline/timeline_model.dart';

void main() {
  group('§1 timeline geometry', () {
    // WHY: the owner codified the proportions (3/6, 2/6, 1/6); a screen
    // without a lane must not leave a hole in the plot.
    test('lane fractions are 3/6, 2/6 and 1/6, top to bottom', () {
      final l = laneLayout(180, TimelineLane.values.toSet());
      expect([for (final x in l) x.lane], TimelineLane.values);
      expect([for (final x in l) x.height], [90, 60, 30]);
      expect([for (final x in l) x.top], [0, 90, 150]);
    });
    test('a lane a screen does not use gives its share to heart rate', () {
      final l = laneLayout(180, {TimelineLane.heartRate, TimelineLane.movement});
      expect([for (final x in l) (x.lane, x.height)],
          [(TimelineLane.heartRate, 150), (TimelineLane.movement, 30)]);
    });

    // WHY: below 30 minutes the minute ticks and the 5-minute epochs stop
    // meaning anything; every zoom path goes through clampTo.
    test('the zoom floor is 30 minutes, on every path', () {
      const domain = (0.0, 86400.0);
      expect(const TimelineView(1000, 1300).clampTo(domain.$1, domain.$2).span,
          kMinViewSec);
      var v = const TimelineView(0, 86400);
      for (var i = 0; i < 40; i++) {
        v = v.zoomAt(40000, domain.$1, domain.$2);
      }
      expect(v.span, kMinViewSec);
      expect(framing(40000, 40060, domain.$1, domain.$2).span,
          greaterThanOrEqualTo(kMinViewSec));
      expect(ZoomSelection.around(const TimelineView(0, 3600), 10).b -
          ZoomSelection.around(const TimelineView(0, 3600), 10).a,
          greaterThanOrEqualTo(kMinViewSec));
      expect(const ZoomSelection(0, 4000).move(false, 100).b, kMinViewSec);
    });

    test('a double tap zooms in by 30% centred on the tap point', () {
      const v = TimelineView(0, 36000);
      final z = v.zoomAt(14000, 0, 86400);
      expect(z.span, closeTo(36000 * .7, 1e-6));
      expect(z.center, closeTo(14000, 1e-6));
      // Near an edge the view shifts back inside the day, keeping the scale.
      final e = v.zoomAt(1000, 0, 86400);
      expect(e.span, closeTo(36000 * .7, 1e-6));
      expect(e.start, 0);
    });

    // WHY: spec "Every zoom change animates over 1.5–2 s, longer for bigger
    // ratio changes".
    test('the zoom animation lasts 1.5 to 2 s, longer for bigger changes', () {
      const day = TimelineView(0, 86400);
      final pan = zoomDuration(day, const TimelineView(3600, 90000));
      final small = zoomDuration(day, day.zoomAt(40000, 0, 86400));
      final big = zoomDuration(day, const TimelineView(0, 1800));
      final out = zoomDuration(const TimelineView(0, 1800), day);
      for (final d in [pan, small, big, out]) {
        expect(d.inMilliseconds, inInclusiveRange(1500, 2000));
      }
      expect(pan.inMilliseconds, 1500);
      expect(small, lessThan(big));
      expect(big.inMilliseconds, 2000);
      expect(out, big);
      // Ease in and out: slow at both ends, the midpoint at half.
      expect(easeInOut(.5), closeTo(.5, 1e-9));
      expect(easeInOut(.1), lessThan(.1));
      expect(easeInOut(.9), greaterThan(.9));
    });
  });

  group('§2 interaction rules (pure halves)', () {
    const main = SleepBlock('main', BlockKind.main, 10000, 40000);
    const nap = SleepBlock('nap1', BlockKind.nap, 50000, 53600);
    List<SleepBlock> move(String id, BlockEnd w, int to) => moveBlockEnd(
        const [main, nap], id, w, to, domainStart: 0, domainEnd: 86400);

    // WHY: owner decision "no overlapping blocks": a dragged end stops at the
    // neighbouring block's edge.
    test('blocks never overlap: a dragged end stops at the neighbour', () {
      expect(move('main', BlockEnd.end, 60000).first.end, nap.start);
      expect(move('nap1', BlockEnd.start, 0).last.start, main.end);
      expect(blocksOverlap(move('main', BlockEnd.end, 60000)), isFalse);
      // A block never inverts or shrinks below the minimum.
      expect(move('main', BlockEnd.start, 39990).first.length, kMinBlockSec);
      // Nor leaves the night.
      expect(move('main', BlockEnd.start, -500).first.start, 0);
      for (var to = 0; to < 86400; to += 997) {
        for (final w in BlockEnd.values) {
          for (final id in ['main', 'nap1']) {
            expect(blocksOverlap(move(id, w, to)), isFalse, reason: '$id $w $to');
          }
        }
      }
    });

    test('Add sleep block places a nap on the asked side, clear of others', () {
      final before = placeNap(const [main], before: true,
          domainStart: 0, domainEnd: 86400, id: 'n')!;
      expect(before.end, lessThanOrEqualTo(main.start));
      final after = placeNap(const [main, nap], before: false,
          domainStart: 0, domainEnd: 86400, id: 'n2')!;
      expect(after.start, greaterThanOrEqualTo(main.end));
      expect(blocksOverlap([main, nap, after]), isFalse);
      expect(placeNap(const [SleepBlock('m', BlockKind.main, 100, 86000)],
          before: true, domainStart: 0, domainEnd: 86400, id: 'x'), isNull);
    });

    // WHY: spec "moves in 5-minute steps at first. Held still for about 0.6 s,
    // it switches to 1-minute steps at a quarter of the finger speed."
    test('the magnifier switches from 5-minute to 1-minute steps after a hold', () {
      final d = MagnifierDrag(36000);
      // 30 s per px: coarse values are multiples of 5 minutes.
      for (final px in [10.0, 13.0, 17.0, 29.0]) {
        expect(d.update(px, 36000 + px * 30 + 77, 30) % 300, 0);
      }
      final atHold = d.value;
      expect(d.hold(), isTrue);
      expect(d.fine, isTrue);
      expect(d.update(100, 0, 30), atHold); // the anchor, no jump
      // 8 px at 30 s/px is 240 s of finger, a quarter is 60 s: one minute.
      expect(d.update(108, 0, 30), atHold + 60);
      expect(d.update(116, 0, 30), atHold + 120);
      expect((d.value - atHold) % 60, 0);
      expect(d.hold(), isFalse);
      expect(kFineHold, const Duration(milliseconds: 600));
    });

    test('haptic tiers by minute value', () {
      expect(hapticTier(7 * 60 + 1), HapticTier.minute);
      expect(hapticTier(7 * 60 + 5), HapticTier.five);
      expect(hapticTier(7 * 60 + 10), HapticTier.ten);
      expect(hapticTier(7 * 60 + 30), HapticTier.thirty);
      expect(hapticTier(7 * 60), HapticTier.hour);
      expect(hapticTier(0), HapticTier.hour);
      expect(hapticTier(23 * 60 + 55), HapticTier.five);
    });
  });

  group('§5 stage wave', () {
    const a = SleepStage.awake, r = SleepStage.rem, l = SleepStage.light,
        d = SleepStage.deep;

    // WHY: owner decision "wake spikes unsmoothed": smoothing never crosses
    // an Awake epoch, so a short wake-up is a spike to the top and the sleep
    // beside it is not dragged up towards it.
    test('never smoothed across Awake epochs', () {
      final w = stageWave([d, d, d, a, d, d, d]).single;
      expect(w[3].depth, 0);
      expect(w[3].stage, a);
      // Deep either side stays fully deep: the awake value is not averaged in.
      for (final i in [0, 1, 2, 4, 5, 6]) {
        expect(w[i].depth, 3, reason: 'epoch $i');
      }
      // What lies beyond the wake-up never reaches across it.
      final left = stageWave([l, l, d, a, r, r, r]).single;
      final left2 = stageWave([l, l, d, a, d, d, d]).single;
      expect(left[2].depth, left2[2].depth);
      expect(left[4].depth, 1);
    });
    test('neighbouring sleep epochs are smoothed; a gap breaks the wave', () {
      final w = stageWave([l, d, l, l]).single;
      expect(w[1].depth, closeTo((2 + 3 + 2 + 2) / 4, 1e-9));
      final runs = stageWave([l, l, null, d, d]);
      expect(runs.length, 2);
      expect(runs.last.first.depth, 3); // not pulled by the run before the gap
    });
  });

  group('preview stager', () {
    // WHY: spec "updates live while dragging, at under 16 ms per update on
    // the phone". The bar here is far stricter (a desktop runner): 24 hours
    // of minutes, two blocks, one stage-and-totals update well under 2 ms.
    test('one update over a 24-hour night stays far under 16 ms', () {
      final hr = [for (var i = 0; i < 1440; i++) 55.0 + (i % 17)];
      final mv = [for (var i = 0; i < 1440; i++) (i % 97 == 0) ? .8 : .05];
      final blocks = [const SleepBlock('m', BlockKind.main, 3 * 3600, 11 * 3600),
        const SleepBlock('n', BlockKind.nap, 17 * 3600, 18 * 3600)];
      for (var i = 0; i < 50; i++) {
        previewStages(domainStart: 0, hr: hr, movement: mv, blocks: blocks);
      }
      final sw = Stopwatch()..start();
      const runs = 500;
      for (var i = 0; i < runs; i++) {
        final s = previewStages(domainStart: 0, hr: hr, movement: mv, blocks: blocks);
        previewTotals(s, 0, blocks.first);
        stageWave(s);
      }
      final perUpdateUs = sw.elapsedMicroseconds / runs;
      // ignore: avoid_print
      print('preview stager: ${perUpdateUs.toStringAsFixed(1)} µs per update');
      expect(perUpdateUs, lessThan(2000));
    });
    test('outside every block is null; heavy movement is Awake', () {
      final mv = [for (var i = 0; i < 120; i++) i >= 60 && i < 65 ? .9 : .05];
      final s = previewStages(domainStart: 0, hr: List.filled(120, 55.0),
          movement: mv, blocks: [const SleepBlock('m', BlockKind.main, 1800, 7200)]);
      expect(s.take(6), everyElement(isNull));
      expect(s[12], SleepStage.awake);
      expect(s.skip(6).where((x) => x == null), isEmpty);
    });
    test('suggestions snap to where movement settles and rises', () {
      final mv = [for (var m = 0; m < 600; m++) m < 100 || m >= 500 ? .6 : .05];
      final b = const SleepBlock('m', BlockKind.main, 70 * 60, 530 * 60);
      final s = endSuggestions(mv, 0, b);
      expect(s.map((x) => (x.which, x.at)),
          [(BlockEnd.start, 100 * 60), (BlockEnd.end, 500 * 60)]);
      // An end already there is not suggested again.
      expect(endSuggestions(mv, 0, const SleepBlock('m', BlockKind.main, 6000, 30000)), isEmpty);
    });
  });
}
