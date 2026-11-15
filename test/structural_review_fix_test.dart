// Review F1/F3/F6/F7/F8/F15: exercise visible meaning and the actual paint/layer
// boundary, rather than asserting an animation controller's input value.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/sleep_detail.dart';
import 'package:openstrap_edge/ui2/skeleton/skeleton.dart';
import 'package:openstrap_edge/ui2/skeleton/placeholder_paint.dart';
import 'support/skeleton_fixture.dart';

void main() {
  testWidgets('F1 answer uses watched denominator and zero gaps stay silent', (t) async {
    skTallView(t);
    Future<void> show(double gap) => t.pumpWidget(skHost(SleepDetail(data: SleepData(
      unobservedMin: gap, night: const {'duration_min': 350, 'in_bed_min': 486, 'efficiency': .92}))));
    await show(106);
    final answer = find.byKey(const ValueKey('card:answer'));
    expect(find.descendant(of: answer, matching: find.text('ASLEEP')), findsOneWidget);
    expect(find.descendant(of: answer, matching: find.text('WATCHED')), findsOneWidget);
    await show(0);
    expect(find.textContaining('The band covered'), findsNothing);
    expect(find.text('WATCHED'), findsNothing);
  });
  testWidgets('F3 guide ink is immediate even while its dim is at 10 percent', (t) async {
    final recorder = ui.PictureRecorder();
    paintSkeletonShapes(Canvas(recorder), [SkeletonShape(kind: SkeletonKind.bar,
      rect: const Rect.fromLTWH(0, 0, 20, 20), section: 0, color: Colors.red)],
      const P(true), fade: .1);
    final picture = recorder.endRecording();
    final alpha = await t.runAsync(() async {
      final image = await picture.toImage(20, 20);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final a = data!.getUint8((10 * 20 + 10) * 4 + 3);
      image.dispose(); return a;
    });
    picture.dispose();
    expect(alpha, 255);
  });
  testWidgets('F6 all placeholder chrome fades under one opacity layer', (t) async {
    await t.pumpWidget(skHost(const PendingContent(pending: true,
      child: Surface(child: Text('Stored answer')))));
    await t.pump(const Duration(milliseconds: 199));
    expect(t.layers.whereType<OpacityLayer>().where((l) => (l.alpha ?? 0) > 0 && (l.alpha ?? 0) < 255), isEmpty);
    await t.pump(const Duration(milliseconds: 1));
    await t.pump(const Duration(milliseconds: 125));
    expect(t.layers.whereType<OpacityLayer>().where((l) => (l.alpha ?? 0) > 0 && (l.alpha ?? 0) < 255), isNotEmpty);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('F7 pending paint plans survive ten pulse frames and isolate repaints', (t) async {
    GuidePlaceholderPaint.planBuilds = 0;
    await t.pumpWidget(skHost(const PendingContent(pending: true,
      child: Surface(child: Text('Stored answer')))));
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 300));
    final built = GuidePlaceholderPaint.planBuilds;
    for (var i = 0; i < 10; i++) { await t.pump(const Duration(milliseconds: 50)); }
    expect(GuidePlaceholderPaint.planBuilds, built);
    final RenderObject render = t.renderObject(find.byType(PendingContent));
    var found = false;
    void visit(RenderObject r) { if (r.runtimeType.toString() == '_RenderPending') found = r.isRepaintBoundary; r.visitChildren(visit); }
    visit(render);
    expect(found, isTrue);
    await t.pumpWidget(const SizedBox());
  });
  test('F8 review wait copy and source disclosure are translated in every locale', () {
    for (final lang in ['en','de','es','fr','hi','ru','zh']) {
      final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map;
      for (final key in ['reviewWaitingImportTitle','reviewWaitingImportBody','reviewReadActivities','reviewReadMoments','reviewReadDays','reviewReadSaved','metricSourcesUsed']) {
        expect(arb[key], isA<String>(), reason: '$lang $key');
      }
    }
  });
}
