// A box height must come from its parts. Scaling a whole height as if it were
// a font size under-grows it when text scaling is nonlinear (Android 14+):
// the text grows, the box barely does, the content clips.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:openstrap_edge/data/import_progress.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/ui2/profile/import_progress_view.dart';
import 'package:openstrap_edge/ui2/status_line.dart';
import 'package:openstrap_edge/ui2/theme.dart';

/// 13 -> 26 but 130 -> 135: font sizes double, big lengths barely.
class _Nonlinear extends TextScaler {
  const _Nonlinear();
  @override
  double scale(double fontSize) => fontSize < 40 ? fontSize + 13 : fontSize + 5;
  @override
  double get textScaleFactor => 2;
  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = double.infinity}) => this;
  @override
  bool operator ==(Object o) => o is _Nonlinear;
  @override
  int get hashCode => 1;
}

Widget _host(Widget child) => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(textScaler: _Nonlinear()),
        child: Scaffold(body: ListView(children: [child])),
      ),
    );

void main() {
  testWidgets('import view: no overflow, one height across states',
      (t) async {
    const states = <ImportProgress>[
      ImportPreparing(),
      ImportCopying(ImportStage.heartRate, 1234567, 9876543, 4, 9),
      ImportRebuilding(3, 12, '2026-10-04'),
      ImportFailed('x'),
    ];
    final heights = <double>[];
    for (final s in states) {
      await t.pumpWidget(_host(ImportProgressView(s)));
      expect(t.takeException(), isNull, reason: '$s overflowed');
      heights.add(t.getSize(find.byType(ImportProgressView)).height);
    }
    expect(heights.toSet().length, 1, reason: '$heights');
  });

  testWidgets('status line box is exactly one scaled line plus padding',
      (t) async {
    final app = AppState.forTesting();
    addTearDown(app.dispose);
    await t.pumpWidget(_host(ChangeNotifierProvider<AppState>.value(
        value: app, child: const StatusLine(todayId: '2026-10-04'))));
    expect(t.takeException(), isNull);
    final box = t.getSize(find.byType(StatusLine)).height;
    // One cap line at the scaled FONT size (13 -> 26), not the scaled line
    // height (18 -> 31): 26 * 18/13 = 36, plus 2 * S.x1 padding.
    expect(box, closeTo(26 * 18 / 13 + 8, 0.01));
  });
}
