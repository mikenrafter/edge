// Owner: one controller owns the range, zoom selection and persistent scrub.
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'timeline_model.dart';
export 'timeline_model.dart';
class TimelineController extends ChangeNotifier {
  TimelineController({required int homeStartSec, required int homeEndSec})
      : home = TimelineView(homeStartSec.toDouble(), homeEndSec.toDouble());
  final TimelineView home;
  TimelineView get view => home;
  final range = ChangeNotifier(), scrubChanges = ChangeNotifier(), zoomChanges = ChangeNotifier();
  double? get scrub => null;
  TimelineView? get selection => null;
  bool get zoomed => false;
  bool get animating => false;
  void attach(TickerProvider vsync, {required bool reducedMotion}) {}
  void detach(TickerProvider vsync) {}
  void selectRange(int startSec, int endSec) {}
  void resetZoom() {}
  void zoomAt(double t) {}
  void toggleZoomSelection() {}
  void moveZoomHandle(bool first, double t) {}
  void setScrub(double t) {}
  void reveal(double t) {}
}
