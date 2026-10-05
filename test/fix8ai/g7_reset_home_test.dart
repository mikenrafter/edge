// 8AI.2 G7 (red first): "Reset all data" lives on the Your data screen, in its
// Advanced section, and nowhere else.
//
// USER REPORT (APK f88d230c): "Move the delete all data button into the import
// and export sub-screen. It really shouldn't be so front and center." It was a
// red row at the foot of the Settings landing.
//
// ASSUMED:
//   * MoreSettingsView no longer draws the row and has no `onReset`; the
//     confirmation flow (_confirmReset) is gone from settings.dart.
//   * DataScreenView takes `VoidCallback? onReset`. Its Advanced accordion ends
//     with a danger row "Reset all data", after "Rebuild all history"; a null
//     callback (or a busy screen) leaves it inert.
//   * data.dart owns the flow, unchanged: the same dialog ("Delete everything?",
//     "Keep my data" / "Delete everything"), AppState.resetAllData, the backup
//     folder pruned to zero, then backToRoot.
//   * One home: only data.dart calls resetAllData in lib/ui2.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/profile/data.dart';
import 'package:openstrap_edge/ui2/profile/settings.dart';
import 'package:openstrap_edge/ui2/ui2.dart' show buildTheme;

import '../phase8/support/dart_source.dart';
import '../phase8/support/sections.dart';

Widget _data({VoidCallback? onReset, bool busy = false}) {
  try {
    return Function.apply(DataScreenView.new, const [], {
      #onReset: onReset,
      #busy: busy,
    }) as Widget;
  } on NoSuchMethodError {
    return DataScreenView(busy: busy);
  }
}

void main() {
  testWidgets('Settings no longer has the row', (t) async {
    await pumpTall(t, const MoreSettingsView(devMode: true, relaySupported: true));
    expect(find.text('Reset all data'), findsNothing);
  });

  testWidgets('Your data: the last row of Advanced, after Rebuild all history',
      (t) async {
    await pumpTall(t, _data(onReset: () {}));
    final reset = find.descendant(
        of: section('Advanced'), matching: find.text('Reset all data'));
    expect(reset, findsOneWidget);
    final rebuild = find.descendant(
        of: section('Advanced'), matching: find.text('Rebuild all history'));
    expect(t.getTopLeft(reset).dy, greaterThan(t.getTopLeft(rebuild).dy));
    // Nothing of the screen's content sits below it but the accordion's end.
    expect(t.getBottomLeft(reset).dy,
        lessThanOrEqualTo(t.getBottomLeft(section('Advanced')).dy));
    for (final g in sectionTitles(t)) {
      expect(t.getBottomLeft(section(g)).dy,
          lessThanOrEqualTo(t.getBottomLeft(section('Advanced')).dy),
          reason: 'Advanced is still the last group');
    }
  });

  testWidgets('tapping it calls onReset once; busy leaves it inert',
      (t) async {
    var n = 0;
    await pumpTall(t, _data(onReset: () => n++));
    await t.tap(find.text('Reset all data'));
    await t.pump();
    expect(n, 1);
    // Busy draws a spinner that never settles: one pump, not pumpAndSettle.
    await t.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: _data(onReset: () => n++, busy: true)));
    await t.pump();
    await t.tap(find.text('Reset all data'), warnIfMissed: false);
    await t.pump();
    expect(n, 1, reason: 'a second tap while another action runs does nothing');
  });

  group('one home, flow unchanged', () {
    test('no other screen in lib/ui2 calls resetAllData', () {
      final hits = [
        for (final f in Directory('lib/ui2')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')))
          if (codeOnly(f.readAsStringSync()).contains('resetAllData()'))
            f.path,
      ];
      expect(hits, ['lib/ui2/profile/data.dart']);
    });
  });
}
