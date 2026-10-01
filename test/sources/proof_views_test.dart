// Phase 4 headless proof: Source catalog and Resolved data pure views in
// light/dark at 1x/2x text scale. Synthetic fixtures only.
//
// Red phase: the views do not exist, so every case fails on the missing
// factory before any golden is compared. Goldens are generated in the green
// phase under test/sources/goldens/. Not in test/proof/ by design.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;
import 'support/fonts.dart';
import 'support/sources_support.dart';

void main() {
  setUpAll(loadFonts);
  final h0 = sec(2026, 9, 1, 0), h2 = sec(2026, 9, 1, 2), h3 = sec(2026, 9, 1, 3), h4 = sec(2026, 9, 1, 4);

  Widget catalog(dynamic v) => sourcesContract(
    'SourceViews.catalog(cards:)',
    () =>
        v.catalog(
              cards: [
                cardFixture(
                  deviceId: kStrapA,
                  suffix: '2c3d',
                  platformIdSuffix: 'EE01',
                  coverage: {
                    'rrIntervals': {'start': h0, 'end': h4},
                  },
                  lastSeen: h4,
                ),
                cardFixture(
                  deviceId: kStrapB,
                  suffix: '7d6c',
                  platformIdSuffix: 'EE02',
                  uses: const [],
                ),
                cardFixture(
                  deviceId: kPrimary,
                  name: 'WHOOP',
                  suffix: null,
                  type: 'band',
                  platformIdSuffix: null,
                  collection: 'continuous',
                  signals: const ['hr1Hz', 'rrIntervals'],
                  limitations: const [],
                  uses: const [
                    {
                      'signal': 'hr1Hz',
                      'reasonCode': 'onlySource',
                      'reason': 'Only the band declares heart rate.',
                    },
                  ],
                ),
                cardFixture(
                  deviceId: '',
                  name: 'This phone',
                  suffix: null,
                  type: 'phone',
                  model: null,
                  platformIdSuffix: null,
                  collection: 'sampled',
                  signals: const [],
                  permissions: const [],
                  limitations: const [],
                  uses: const [],
                ),
              ],
            )
            as Widget,
  );

  Widget resolved(dynamic v) => sourcesContract(
    'SourceViews.resolvedData(rows:, names:)',
    () =>
        v.resolvedData(
              rows: [
                intervalFixture(
                  start: h0,
                  end: h2,
                  kind: 'single',
                  winner: kPrimary,
                  alternatives: const [],
                  agreement: 'single',
                  reasonCode: 'onlySource',
                  reason: 'Only the band was recording.',
                ),
                intervalFixture(start: h2, end: h3),
                intervalFixture(
                  start: h2,
                  end: h3,
                  signal: 'hr1Hz',
                  winner: kPrimary,
                  alternatives: const [kStrapA],
                  agreement: 'disagree',
                  reasonCode: 'defaultPrimary',
                  reason: 'No order is set, so the band owns heart rate.',
                  values: {kPrimary: 60.0, kStrapA: 85.0},
                ),
                intervalFixture(
                  start: h3,
                  end: h4,
                  kind: 'gap',
                  winner: null,
                  alternatives: const [],
                  agreement: 'none',
                  reasonCode: 'noCoverage',
                  reason: 'Nothing was recording.',
                ),
              ],
              names: kFixtureNames,
            )
            as Widget,
  );

  final fixtures = <String, (double, Widget Function(dynamic))>{
    'source_catalog': (2600, catalog),
    'resolved_data': (1800, resolved),
  };
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      for (final fixture in fixtures.entries) {
        final name = '${fixture.key}_${brightness.name}_${scale.toInt()}x';
        testWidgets(name, (tester) async {
          final boundary = GlobalKey();
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(390, fixture.value.$1);
          addTearDown(tester.view.reset);
          final dynamic views = openViews();
          final Widget view = fixture.value.$2(views);
          await tester.pumpWidget(
            MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: buildTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: RepaintBoundary(
                key: boundary,
                child: Scaffold(body: SingleChildScrollView(child: view)),
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byKey(boundary),
            matchesGoldenFile('goldens/$name.png'),
          );
          final directory = Platform.environment['EDGE_PROOF_DIR'];
          if (directory != null) {
            await tester.runAsync(() async {
              final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final image = await render.toImage(pixelRatio: 1);
              final data = await image.toByteData(format: ui.ImageByteFormat.png);
              final output = File('$directory/$name.png');
              await output.parent.create(recursive: true);
              await output.writeAsBytes(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }
}
