import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ui2/shared_slot.dart';

void main() {
  // Why: a cross-screen measurement marker must not move the actual content.
  // Catches: giving ContentTopMarker a nonzero layout height.
  testWidgets('content marker has no height and keeps its shared identity', (t) async {
    await t.pumpWidget(const Directionality(textDirection: TextDirection.ltr,
      child: Align(alignment: Alignment.topLeft, child: SizedBox(width: 200,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ContentTopMarker(), SizedBox(key: ValueKey('content'), height: 30),
        ])))));
    expect(t.getSize(find.byType(ContentTopMarker)).height, 0);
    expect(t.getTopLeft(find.byKey(const ValueKey('content'))).dy, 0);
    expect(find.byKey(const ValueKey('shared:content-top')), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
