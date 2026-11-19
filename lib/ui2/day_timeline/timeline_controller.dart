// Owner: one controller owns range animation, zoom selection and persistent scrub.
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'timeline_model.dart';
import '../theme.dart' show Motion;
export 'timeline_model.dart';

// CLAIM(timeline-shared-zoom): every chart uses this range and gesture policy
// [sleep-structural spec §4.3; sleep_shared_timeline_test]. Separate channels
// keep pure zoom frames from rebuilding readout Text or the activity list.
class TimelineController extends ChangeNotifier {
  TimelineController({required int homeStartSec, required int homeEndSec,this.glideDuration})
    : assert(homeEndSec > homeStartSec),
      home = TimelineView(homeStartSec.toDouble(), homeEndSec.toDouble()),
      _view = TimelineView(homeStartSec.toDouble(), homeEndSec.toDouble());
  final TimelineView home;
  final Duration? glideDuration;
  TimelineView _view;
  TimelineView get view => _view;
  final range = ChangeNotifier(),
      scrubChanges = ChangeNotifier(),
      zoomChanges = ChangeNotifier();
  double? _scrub;
  double? get scrub => _scrub;
  TimelineView? _selection;
  TimelineView? get selection => _selection;
  bool get zoomed => (_to ?? _view) != home;
  bool get animating => _ticker?.isActive == true;
  TickerProvider? _vsync;
  Ticker? _ticker, _scrubTicker;
  double? _scrubFrom, _scrubTo;
  bool _reducedMotion = false;
  TimelineView? _from, _to;
  Duration _duration = Duration.zero;

  void attach(TickerProvider vsync, {required bool reducedMotion}) {
    if (!identical(_vsync, vsync)) {
      _ticker?.dispose();
      _scrubTicker?.dispose();
      _scrubTicker = null;
      _vsync = vsync;
      _ticker = vsync.createTicker(_tick);
    }
    _reducedMotion = reducedMotion;
    if (reducedMotion && _to != null) {
      _ticker?.stop();
      _view = _to!;
      _to = null;
      range.notifyListeners();
    }
    if (reducedMotion && _scrubTo != null) {
      _scrubTicker?.stop();
      _scrub = _scrubTo;
      _scrubTo = null;
      scrubChanges.notifyListeners();
    }
  }

  void detach(TickerProvider vsync) {
    if (!identical(_vsync, vsync)) return;
    _ticker?.dispose();
    _ticker = null;
    _scrubTicker?.dispose();
    _scrubTicker = null;
    _scrubTo = null;
    _vsync = null;
    if (_to != null) _view = _to!;
    _to = null;
    _from = null;
  }

  void _tick(Duration elapsed) {
    final to = _to, from = _from;
    if (to == null || from == null) return;
    final k = elapsed.inMicroseconds / _duration.inMicroseconds;
    _view = k >= 1 ? to : from.lerp(to, easeInOut(k));
    if (k >= 1) {
      _ticker?.stop();
      _to = null;
    }
    range.notifyListeners();
  }

  void _glide(TimelineView proposed) {
    final to = proposed.clampTo(home.start, home.end);
    _ticker?.stop();
    // Retarget from pixels currently shown, never the abandoned destination.
    _from = _view;
    _duration = glideDuration??Motion.timelineGlideTime(zoomGlideMilliseconds(_view, to));
    _to = to;
    if (_ticker == null || _reducedMotion || _view == to) {
      _view = to;
      _to = null;
      range.notifyListeners();
    } else {
      _ticker!.start();
    }
    zoomChanges.notifyListeners();
    notifyListeners();
  }

  void selectRange(int startSec, int endSec) {
    if (endSec <= startSec) return;
    _selection = null;
    _glide(TimelineView(startSec.toDouble(), endSec.toDouble()));
  }

  void resetZoom() {
    _selection = null;
    _glide(home);
  }

  void zoomAt(double t) {
    _selection = null;
    _glide(_view.zoomAt(t, home.start, home.end));
  }

  void toggleZoomSelection() {
    final chosen = _selection;
    if (chosen != null) {
      _selection = null;
      _glide(chosen);
      return;
    }
    if (zoomed) {
      resetZoom();
      return;
    }
    final half = (_view.span * .2).clamp(
      900.0,
      _view.span / 2 < 900 ? 900 : _view.span / 2,
    );
    final center = _scrub ?? _view.center;
    _selection = TimelineView(
      center - half,
      center + half,
    ).clampTo(home.start, home.end);
    zoomChanges.notifyListeners();
    notifyListeners();
  }

  void moveZoomHandle(bool first, double t) {
    final s = _selection;
    if (s == null) return;
    final floor = home.span < 1800 ? home.span : 1800.0;
    _selection = first
        ? TimelineView(t.clamp(home.start, s.end - floor), s.end)
        : TimelineView(s.start, t.clamp(s.start + floor, home.end));
    zoomChanges.notifyListeners();
  }

  void clearScrub() {
    _scrubTicker?.stop(); _scrubTo=null; _scrub=null; scrubChanges.notifyListeners();
  }

  void panBy(double seconds) => panTo(_view.start+seconds);
  void panTo(double start) {
    _ticker?.stop(); _to=null;
    _view=TimelineView(start,start+_view.span).clampTo(home.start,home.end);
    range.notifyListeners(); zoomChanges.notifyListeners();
  }
  void beginPilotSelection() {
    clearScrub();
    _selection=_selection==null?TimelineView(_view.start,_view.end):null;
    zoomChanges.notifyListeners();
  }
  void updatePilotSelection(double first,double second) {
    _selection=TimelineView(first<second?first:second,first<second?second:first);
    zoomChanges.notifyListeners();
  }
  void finishPilotSelection() {
    final selected=_selection; _selection=null;
    clearScrub();
    if(selected!=null&&selected.span>=1200)_glide(selected);
    else zoomChanges.notifyListeners();
  }

  void setScrub(double t) {
    _scrubTicker?.stop();
    _scrubTo = null;
    _scrub = t.clamp(home.start, home.end);
    scrubChanges.notifyListeners();
  }

  void reveal(double t) {
    final to = t.clamp(home.start, home.end);
    if (_vsync == null || _reducedMotion || _scrub == null) {
      setScrub(to);
    } else {
      _scrubFrom = _scrub;
      _scrubTo = to;
      _scrubTicker ??= _vsync!.createTicker(_tickScrub);
      _scrubTicker!
        ..stop()
        ..start();
    }
    if (t < _view.start || t > _view.end) {
      _glide(TimelineView(t - _view.span / 2, t + _view.span / 2));
    }
  }

  void _tickScrub(Duration elapsed) {
    final to = _scrubTo, from = _scrubFrom;
    if (to == null || from == null) return;
    final k = elapsed.inMicroseconds / 450000;
    _scrub = k >= 1 ? to : from + (to - from) * easeInOut(k);
    if (k >= 1) {
      _scrubTicker?.stop();
      _scrubTo = null;
    }
    scrubChanges.notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _scrubTicker?.dispose();
    _scrubTicker = null;
    _vsync = null;
    range.dispose();
    scrubChanges.dispose();
    zoomChanges.dispose();
    super.dispose();
  }
}
