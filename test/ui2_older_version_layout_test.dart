// RULES B.2 layout: the asterisk is plain text beside the number. A flagged
// value takes exactly the room an unflagged one does, so nothing moves.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/models/metric.dart';
import 'package:openstrap_edge/ui2/screens/screens.dart';
import 'package:openstrap_edge/ui2/ui2.dart';

import 'support/older_version_fixtures.dart';

const _rec = Metric(value: 82, confidence: .8, tier: MetricTier.high);
const _flagged = Metric(
    value: 8.4,
    confidence: .8,
    tier: MetricTier.estimate,
    fromOlderVersion: 104,
    olderVersionReason: kReasonRaw);
const _plain = Metric(value: 8.4, confidence: .8, tier: MetricTier.estimate);

void _phone(WidgetTester t, double w) {
  t.view.physicalSize = Size(w * 3, 2400 * 3);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> _rings(WidgetTester t, Metric strain) async {
  await t.pumpWidget(MaterialApp(
    theme: buildTheme(Brightness.light),
    home: Scaffold(
        body: SingleChildScrollView(
            child: RingTrio(
                d: HomeData(
                    dayId: '2026-10-04', readiness: _rec, strain: strain),
                now: DateTime(2026, 10, 4, 15)))),
  ));
  await t.pump();
}

void main() {
  testWidgets('Home 360: the strain value and its asterisk share one line',
      (t) async {
    _phone(t, 360);
    await _rings(t, _flagged);
    final v = t.getRect(find.text('8.4'));
    final m = t.getRect(olderMark('strain'));
    expect(m.top, lessThan(v.bottom), reason: 'same row, not wrapped below');
    expect(m.bottom, greaterThan(v.top));
    expect(m.left - v.right, inInclusiveRange(-1, 4),
        reason: 'directly right of the value');
  });

  testWidgets('Home 360: "of 21" sits where it does without the mark',
      (t) async {
    _phone(t, 360);
    await _rings(t, _plain);
    final y = t.getTopLeft(find.text('of 21')).dy;
    await _rings(t, _flagged);
    expect(t.getTopLeft(find.text('of 21')).dy, y);
  });

  testWidgets('the Active energy tile is the same height flagged or not',
      (t) async {
    _phone(t, 360);
    Future<double> height({required bool older}) async {
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: 170,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      SignalCard(Icons.bolt, C.orange, 'Active energy',
                        '420',
                        unit: 'kcal',
                        sub: '2100 total',
                        olderVersion: older ? 104 : null,
                        olderReason: older ? kReasonRaw : null,
                        olderTotalVersion: older ? 104 : null,
                        olderTotalReason: older ? kReasonRaw : null)
                    ])))),
      ));
      await t.pump();
      return t.getSize(find.byType(SignalCard)).height;
    }

    final plain = await height(older: false);
    expect(await height(older: true), plain);
  });

  testWidgets('a scrub readout with a flagged cell is as tall as without',
      (t) async {
    _phone(t, 360);
    Future<double> height(ChartOlder? older) async {
      await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ChartKeyReadout(scrubbed: true, time: '9:40 AM', cells: [
                  ChartCell('Heart rate (bpm)', C.red,
                      value: '72 bpm', older: older),
                  const ChartCell('Movement', C.blue, value: '34%'),
                ])
                ]))),
      ));
      await t.pump();
      return t.getSize(find.byType(ChartKeyReadout)).height;
    }

    final plain = await height(null);
    final old = await height((version: 104, reason: kReasonRaw));
    expect(old, plain);
  });
}
