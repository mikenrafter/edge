// Drives a real screen through explicit pump offsets and scores it.
//
// Time is the fake-async clock only: every capture is stamped with the offset
// the test asked for, never a clock read. A tap records an Interaction (so the
// scorer applies the latency curve); a background refresh records none.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/layout_shift/layout_shift.dart';

import 'layout_shift_probe.dart';

/// Pump offsets (ms after the start of a phase) captured by default.
const shiftOffsets = [0, 16, 50, 100, 200, 300, 500, 1000, 2000];

/// Phone-sized surface: 390 x 844 logical.
const shiftViewport = ShiftRect(0, 0, 390, 844);

void phoneSurface(WidgetTester t) {
  t.view.physicalSize = const Size(390 * 3, 844 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

class ShiftRun {
  ShiftRun(this.t)
      : probe = ShiftProbe(trackUnkeyed: true, visibleOnly: shiftViewport);
  final WidgetTester t;
  final ShiftProbe probe;
  int now = 0;

  /// Captures the current tree at [now] without pumping.
  void snap() => probe.capture(t, atMs: now);

  /// The user opened this screen at [now] (launch or navigation): the open is
  /// the action the loading sequence answers, so its shifts are in-window,
  /// not charged as unprompted movement.
  void opened([String id = 'screen-open']) {
    snap();
    probe.interactions.add(Interaction(now, id));
  }

  /// Pumps to each offset (relative to the current [now]) and captures.
  Future<void> frames([List<int> offsets = shiftOffsets]) async {
    final base = now;
    for (final o in offsets) {
      final at = base + o;
      final d = at - now;
      await t.pump(Duration(milliseconds: d));
      now = at;
      snap();
    }
  }

  /// A user tap on [f]: baseline frame, Interaction at [now], tap, frames.
  /// [intent] names the element the tap is about (the thing the user expects
  /// to change), when that is not the tapped control itself.
  Future<void> tap(Finder f,
      [List<int> offsets = shiftOffsets, Finder? intent]) async {
    snap();
    final src = probe.idOf(t, f) ?? 'unknown-source';
    final target = intent == null ? null : probe.idOf(t, intent);
    probe.interactions.add(Interaction(now, src, intentTargetId: target));
    await t.tap(f);
    await frames(offsets);
  }

  ShiftReport score([ShiftPolicy p = ShiftPolicy.standard]) =>
      layoutScore(probe.scenario(shiftViewport), p);

  /// Prints the compact report and asserts there are no error findings.
  void expectNoErrors(String name, [ShiftPolicy p = ShiftPolicy.standard]) {
    final r = score(p);
    final txt = formatShiftReport(name, r, probe.frames.length);
    debugPrint(txt);
    printOnFailure(txt);
    expect(r.errors, isEmpty, reason: '$name has error-level shifts');
  }
}

ShiftReport layoutScore(Scenario s, ShiftPolicy p) => score(s, p);

String formatShiftReport(String name, ShiftReport r, int frames) {
  final top = [...r.findings]..sort((a, b) => b.score.compareTo(a.score));
  final b = StringBuffer('[layout-shift] $name: $frames frames, '
      '${r.findings.length} findings, ${r.errors.length} errors, '
      '${r.warnings.length} warnings, total ${r.total.toStringAsFixed(4)}\n');
  b.writeln('  rule | element | atMs | score | severity');
  for (final f in top.take(10)) {
    b.writeln('  ${f.rule} | ${f.elementId} | ${f.atMs} | '
        '${f.score.toStringAsFixed(4)} | ${f.severity.name}');
  }
  return b.toString();
}
