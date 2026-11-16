// The PREVIEW stager (pilot: day-timeline spec §3 "Fast preview stager").
//
// A cheap proxy from movement and heart rate, redrawn on every drag update
// of a block's end. It is NOT the app's sleep staging and never reaches a
// stored row: whatever it draws is labelled PREVIEW, and Save always stores
// the window and lets the full calculation stage the night.
//
// One linear pass over the minutes of each block: no sort, no allocation per
// epoch beyond the output list, so a 24-hour night re-stages in well under a
// millisecond (measured in test/ui2/day_timeline_model_test.dart).

import 'dart:math' as math;

import '../charts.dart' show SleepStage;
import 'timeline_model.dart';

/// Epoch length of the preview, seconds.
const int kPreviewEpochSec = 300;

/// Stages of every epoch of [minutes] minutes starting at [domainStart]
/// (epoch seconds), null outside every block. [hr] and [movement] are per
/// minute from [domainStart] (null: not measured).
///
/// Inside a block: an epoch without measured signals remains unknown.
/// Otherwise an epoch whose mean movement is above 0.4 is Awake (a
/// spike in the wave); otherwise its place in a 90-minute cycle from the
/// block's start says Light, Deep or REM, with Deep favoured early in the
/// night and when heart rate is below the block's mean, REM favoured late.
List<SleepStage?> previewStages({
  required int domainStart,
  required List<double?> hr,
  required List<double?> movement,
  required List<SleepBlock> blocks,
}) {
  final minutes = math.max(hr.length, movement.length);
  final epochs = (minutes * 60 / kPreviewEpochSec).ceil();
  final out = List<SleepStage?>.filled(epochs, null);
  const per = kPreviewEpochSec ~/ 60;
  for (final b in blocks) {
    final e0 = ((b.start - domainStart) / kPreviewEpochSec).floor().clamp(0, epochs);
    final e1 = ((b.end - domainStart) / kPreviewEpochSec).ceil().clamp(0, epochs);
    if (e1 <= e0) continue;
    // The block's mean heart rate, one pass.
    var hrSum = 0.0, hrN = 0;
    for (var m = e0 * per; m < e1 * per && m < hr.length; m++) {
      final v = hr[m];
      if (v != null) {
        hrSum += v;
        hrN++;
      }
    }
    final hrMean = hrN == 0 ? null : hrSum / hrN;
    for (var e = e0; e < e1; e++) {
      var mv = 0.0, mvN = 0, h = 0.0, hN = 0;
      for (var m = e * per; m < (e + 1) * per; m++) {
        if (m < movement.length && movement[m] != null) {
          mv += movement[m]!;
          mvN++;
        }
        if (m < hr.length && hr[m] != null) {
          h += hr[m]!;
          hN++;
        }
      }
      if (mvN == 0 && hN == 0) continue;
      if (mvN > 0 && mv / mvN > .4) {
        out[e] = SleepStage.awake;
        continue;
      }
      final into = (e - e0) * kPreviewEpochSec / 60.0; // minutes into the block
      final phase = (into % 90) / 90, cycle = into ~/ 90;
      final low = hrMean != null && hN > 0 && h / hN < hrMean - 2;
      final deep = math.max(0.0, .5 - cycle * .12) + (low ? .1 : 0);
      final rem = math.min(.5, .1 + cycle * .1);
      out[e] = phase < .15
          ? SleepStage.light
          : phase < .15 + deep
              ? SleepStage.deep
              : phase > 1 - rem
                  ? SleepStage.rem
                  : SleepStage.light;
    }
  }
  return out;
}

/// What the readout says about one block, from the preview. Totals are null
/// when any epoch is unsupported: partial coverage cannot describe a whole night.
class PreviewTotals {
  const PreviewTotals({required this.cycles, required this.deepMin,
      required this.remMin, required this.lightMin, required this.wakeUps});
  final int? cycles, deepMin, remMin, lightMin, wakeUps;
}

PreviewTotals previewTotals(List<SleepStage?> stages, int domainStart, SleepBlock b) {
  final e0 = ((b.start - domainStart) / kPreviewEpochSec).floor().clamp(0, stages.length);
  final e1 = ((b.end - domainStart) / kPreviewEpochSec).ceil().clamp(0, stages.length);
  if (e1 <= e0 || b.start < domainStart ||
      b.end > domainStart + stages.length * kPreviewEpochSec ||
      stages.sublist(e0, e1).any((s) => s == null)) {
    return const PreviewTotals(cycles: null, deepMin: null, remMin: null,
        lightMin: null, wakeUps: null);
  }
  var deep = 0, rem = 0, light = 0, wakeUps = 0;
  SleepStage? prev;
  for (var e = e0; e < e1; e++) {
    final s = stages[e];
    switch (s) {
      case SleepStage.deep: deep++;
      case SleepStage.rem: rem++;
      case SleepStage.light: light++;
      case SleepStage.awake:
        if (prev != null && prev != SleepStage.awake) wakeUps++;
      case null: break;
    }
    prev = s;
  }
  const m = kPreviewEpochSec ~/ 60;
  final asleep = (deep + rem + light) * m;
  return PreviewTotals(cycles: math.max(asleep > 0 ? 1 : 0, (asleep / 90).round()),
      deepMin: deep * m, remMin: rem * m, lightMin: light * m, wakeUps: wakeUps);
}

/// A why-row: snap [which] end of a block to [at] because [reason].
class EndSuggestion {
  const EndSuggestion(this.which, this.at, this.reason);
  final BlockEnd which;
  final int at;
  final SuggestionReason reason;
}

enum SuggestionReason { movementSettled, movementRose }

/// Where the signals change near [b]'s ends: movement settling for at least
/// 15 minutes after being up (fell asleep), and movement rising after a
/// still stretch (woke). Searched within 90 minutes of each end; only offered
/// when at least 5 minutes from where the end already is.
List<EndSuggestion> endSuggestions(
    List<double?> movement, int domainStart, SleepBlock b) {
  double? mv(int minute) =>
      minute >= 0 && minute < movement.length ? movement[minute] : null;
  bool still(int m, int n) {
    for (var k = 0; k < n; k++) {
      final v = mv(m + k);
      if (v == null || v >= .2) return false;
    }
    return true;
  }
  final out = <EndSuggestion>[];
  final s = (b.start - domainStart) ~/ 60, e = (b.end - domainStart) ~/ 60;
  for (var m = s - 90; m <= s + 90; m++) {
    final before = mv(m - 1);
    if (before != null && before > .3 && still(m, 15)) {
      final at = domainStart + m * 60;
      if ((at - b.start).abs() >= 300) {
        out.add(EndSuggestion(BlockEnd.start, at, SuggestionReason.movementSettled));
      }
      break;
    }
  }
  for (var m = e + 90; m >= e - 90; m--) {
    final v = mv(m);
    if (v != null && v > .3 && still(m - 15, 15)) {
      final at = domainStart + m * 60;
      if ((at - b.end).abs() >= 300) {
        out.add(EndSuggestion(BlockEnd.end, at, SuggestionReason.movementRose));
      }
      break;
    }
  }
  return out;
}
