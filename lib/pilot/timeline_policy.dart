// Owner: TimelineInteraction owns gesture/readout state for one pilot chart.
import 'package:flutter/foundation.dart';
import 'dart:math' as math;

enum PilotScrub { temporary, permanent }
enum PilotTimelineTab { pending, saved, discarded }
class TimelineInteraction extends ChangeNotifier {
  TimelineInteraction({this.retention = PilotScrub.permanent});
  final PilotScrub retention;
  bool userPinned = false, handScrubbing = false, autoPinned = false;
  double? cursor;
  bool get pinned => userPinned || autoPinned;
  void startScrub(double at) { cursor=at; handScrubbing=true; autoPinned=true; notifyListeners(); }
  void focus(double at) { if(handScrubbing)return; cursor=at; notifyListeners(); }
  void lift() { handScrubbing=false; if(retention==PilotScrub.temporary) { cursor=null; autoPinned=false; } notifyListeners(); }
  void zoom() { cursor=null; handScrubbing=false; autoPinned=false; notifyListeners(); }
  void scroll() { if(handScrubbing)return; autoPinned=false; handScrubbing=false; notifyListeners(); }
  void togglePin() { userPinned=!userPinned; autoPinned=false; notifyListeners(); }
}
List<int> visibleHeartRateTicks(List<double?> hr, {required int start, required int end}) {
  final values=hr.sublist(start.clamp(0,hr.length),end.clamp(start.clamp(0,hr.length),hr.length))
      .whereType<double>().where((v)=>v.isFinite&&v>0).toList();
  if(values.isEmpty) return [];
  final low=values.reduce(math.min), high=values.reduce(math.max);
  final raw=math.max(5.0,(high-low)*.5);
  final magnitude=math.pow(10,(math.log(raw)/math.ln10).floor()).toDouble();
  final normalized=raw/magnitude;
  final step=(normalized<=1?1:normalized<=2?2:normalized<=5?5:10)*magnitude;
  final lo=((low-(high-low)*.06)/step).floor()*step;
  final hi=((high+(high-low)*.06)/step).ceil()*step;
  return [for(var v=lo;v<=math.max(hi,lo+step);v+=step) v.round()];
}
PilotTimelineTab initialTimelineTab({required bool pending, required bool saved}) => pending?PilotTimelineTab.pending:saved?PilotTimelineTab.saved:PilotTimelineTab.discarded;
