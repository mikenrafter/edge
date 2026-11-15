// CLAIM day-switch-chrome: only fetched data fades. The shared day navigation,
// card paint, icon and metric labels must be pixel-identical throughout it.
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart';
import 'package:openstrap_edge/ui2/screens/metric_detail.dart';
import 'support/skeleton_fixture.dart';

void main() {
  testWidgets(
    'day switch keeps chrome and new date real throughout debounce and fade',
    (t) async {
      skTallView(t, w: 390, h: 844);
      final capture = GlobalKey();
      var pending = false;
      var day = '2026-11-14';
      late StateSetter change;
      await t.pumpWidget(
        skHost(
          StatefulBuilder(
            builder: (c, set) {
              change = set;
              return RepaintBoundary(
                key: capture,
                child: Scaffold(
                  body: Padding(
                    padding: const EdgeInsets.all(20),
                    child: PendingContent(
                      pending: pending,
                      child: Surface(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DayNav(
                              day: day,
                              days: const ['2026-11-14', '2026-11-13'],
                              onDay: (_) {},
                              alwaysShow: true,
                            ),
                            const Icon(
                              Icons.favorite,
                              key: ValueKey('chrome-icon'),
                            ),
                            const InlineMetrics([('RESTING HR', '57', C.red)]),
                            detailLinkRow(c, Icons.schedule, 'Body clock',
                                'Your schedule', () {}),
                            const StatusCard('History', '', fix:'3 of 7 nights so far'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );
      Future<Uint8List> pixels() async {
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final data = await t.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          image.dispose();
          return bytes!.buffer.asUint8List();
        });
        return data!;
      }

      List<int> crop(Uint8List bytes, Rect r) => [
        for (var y = r.top.ceil(); y < r.bottom.floor(); y++)
          for (var x = r.left.ceil(); x < r.right.floor(); x++)
            for (var c = 0; c < 4; c++) bytes[(y * 390 + x) * 4 + c],
      ];
      // Independent reference: the NEW date painted in an ordinary settled card.
      change(() => day = '2026-11-13');
      await t.pump();
      final date = find
          .descendant(of: find.byType(DayNav), matching: find.byType(Text))
          .first;
      final regions = [
        t.getRect(date), t.getRect(find.text('RESTING HR')),
        t.getRect(find.text('Body clock')), t.getRect(find.text('Your schedule')),
        t.getRect(find.byKey(const ValueKey('chrome-icon'))),
        // A strip of the Surface's own background, beside all its content.
        Rect.fromLTWH(
          t.getRect(find.byType(Surface).first).left + 2,
          t.getRect(find.byType(Surface).first).top + 25,
          3,
          40,
        ),
      ];
      final dependentCount = t.getRect(find.text('3 of 7 nights so far'));
      final settled = await pixels();
      change(() {
        day = '2026-11-14';
      });
      await t.pump();
      change(() {
        day = '2026-11-13';
        pending = true;
      });
      await t.pump();
      for (final ms in [0, 100, 100, 125, 125, 200]) {
        await t.pump(Duration(milliseconds: ms));
        final current = await pixels();
        expect(crop(current, dependentCount), isNot(equals(crop(settled, dependentCount))),
            reason: 'history count depends on the new read and must be a placeholder');
        for (final region in regions) {
          final actual=crop(current,region), expected=crop(settled,region);
          expect(
            [for(var i=0;i<actual.length;i++) if(actual[i] != expected[i]) i].length,
            0,
            reason: 'chrome/date changed after ${ms}ms',
          );
        }
      }
      await t.pumpWidget(const SizedBox());
    },
  );
}
