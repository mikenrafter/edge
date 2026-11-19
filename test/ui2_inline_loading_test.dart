// InlineLoading: the one loading primitive. A spinner with a status line
// (what is happening now), an optional detail line, and an optional reserved
// height so the content that lands later fills the space instead of pushing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/inline_loading.dart';
import 'package:openstrap_edge/ui2/skeleton/async_section.dart';
import 'package:openstrap_edge/ui2/theme.dart';

/// Built through Function.apply so this file compiles before InlineLoading
/// takes `status`, `detail` and `height`; until then each case fails with a
/// NoSuchMethodError naming the missing parameter.
Widget _loading(String status, {String? detail, double? height}) =>
    Function.apply(InlineLoading.new, const [], {
      #status: status,
      #detail: detail,
      #height: height,
    }) as Widget;

Future<void> _pump(WidgetTester t, Widget w) => t.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: ListView(children: [w])),
    ));

void main() {
  testWidgets('status and detail remain visible while rows load', (t) async {
    await _pump(
        t,
        _loading('Loading last night', detail: 'Calculating · day 3 of 12'));
    expect(find.text('Loading last night'), findsOneWidget);
    expect(find.text('Calculating · day 3 of 12'), findsOneWidget);
    expect(find.byType(PendingContent), findsOneWidget);
  });

  testWidgets('no detail: only the status', (t) async {
    await _pump(t, _loading('Loading last night'));
    expect(find.text('Loading last night'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
    expect(find.byType(PendingContent), findsOneWidget);
  });

  testWidgets('height reserves the final content height', (t) async {
    await _pump(t, _loading('Loading last night', height: 240));
    expect(t.getSize(find.byType(InlineLoading)).height, 240);
  });
}
