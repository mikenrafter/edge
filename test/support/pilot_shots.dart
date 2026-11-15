// Optional review artifacts, independent of assertions and shift scoring.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final _key = GlobalKey();
Widget pilotShot(Widget child) => RepaintBoundary(key: _key, child: child);
Future<void> takePilotShot(WidgetTester tester, String name) async {
  final dir = Platform.environment['CLS_SHOTS_DIR'];
  if (dir == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_key));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory(dir).create(recursive: true);
      await File('$dir/$name.png').writeAsBytes(data!.buffer.asUint8List());
    } finally { image.dispose(); }
  });
}
