// Owner: SyncStripOverlay State owns only the minute repaint timer.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../ui2/theme.dart';
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import 'pilot_flags.dart';
import 'sync_strip.dart';

DayGraph syncStripVisibleGraph(BuildContext c,DayGraph graph,{required bool enabled}) {
  if(!enabled||!PilotFlag.syncStrip.enabled||graph.dayStart==null)return graph;
  final last=syncStripWindow(c).last;
  if(last==null)return graph;
  final slots=(((last-graph.dayStart!)/60).floor()+1).clamp(0,graph.slots);
  return slots==graph.slots?graph:graph.window(0,slots);
}
List<double?>? syncStripVisibleCurve(BuildContext c,List<double?>? curve,int? start,{required bool enabled}) {
  if(!enabled||!PilotFlag.syncStrip.enabled||curve==null||start==null)return curve;
  final last=syncStripWindow(c).last;
  if(last==null)return curve;
  final length=(last-start+1).clamp(0,curve.length);
  return length==curve.length?curve:curve.sublist(0,length);
}

/// Uses the chart's own time mapping; the day chart keeps its gestures and axes.
class SyncStripOverlay extends StatefulWidget {
  const SyncStripOverlay({super.key,required this.view,this.left=0,this.right=0,this.top=20,this.bottom=24,this.window});
  final TimelineView view;
  final double left,right,top,bottom;
  final SyncStripWindow? window;
  @override State<SyncStripOverlay> createState()=>_SyncStripOverlayState();
}
class _SyncStripOverlayState extends State<SyncStripOverlay>{
  Timer? _timer;
  @override void initState(){super.initState();_timer=Timer.periodic(const Duration(minutes:1),(_){if(mounted)setState((){});});}
  @override void dispose(){_timer?.cancel();super.dispose();}
  @override Widget build(BuildContext c)=>ValueListenableBuilder<int>(valueListenable:PilotFlags.revision,builder:(c,_,child){
    if(!PilotFlag.syncStrip.enabled)return const SizedBox.shrink();
    final window=widget.window??syncStripWindow(c);
    if(window.last==null||window.missing<=0||window.now<widget.view.start||window.last!>=widget.view.end)return const SizedBox.shrink();
    return IgnorePointer(child:Semantics(label:'${window.label}. ${window.backlogLabel}',child:CustomPaint(
      painter:SyncStripOverlayPainter(p:P.of(c),view:widget.view,window:window,left:widget.left,right:widget.right,top:widget.top,bottom:widget.bottom,
        scaler:MediaQuery.textScalerOf(c)))));
  });
}
class SyncStripOverlayPainter extends CustomPainter {
  SyncStripOverlayPainter({required this.p,required this.view,required this.window,this.left=0,this.right=0,this.top=20,this.bottom=24,this.scaler=TextScaler.noScaling});
  final P p;final TimelineView view;final SyncStripWindow window;
  final double left,right,top,bottom;final TextScaler scaler;
  @override void paint(Canvas canvas,Size size){
    final width=math.max(1.0,size.width-left-right),end=left+width;
    double x(num at)=>left+view.fraction(at.toDouble())*width;
    final edge=x(window.last!).clamp(left,end),now=x(window.now).clamp(left,end);
    if(edge>=now)return;
    final base=size.height-bottom;
    canvas.save();canvas.clipRect(Rect.fromLTRB(left,top,end,base));
    final fade=Rect.fromLTRB(math.max(left,edge-24),top,edge,base);
    canvas.drawRect(fade,Paint()..shader=LinearGradient(colors:[p.card.withValues(alpha:0),p.card]).createShader(fade));
    // The mask prevents any cached curve, movement or future annotation from
    // appearing beyond the durable frontier (sync_strip_widget_test).
    canvas.drawRect(Rect.fromLTRB(edge,top,end,base),Paint()..color=p.card);
    paintSyncFade(canvas,Rect.fromLTRB(edge,top,now,base),p,'',reported:window.reported);
    final color=p.on(window.reported?C.domHome:C.n500);
    final label=TextPainter(text:TextSpan(text:'${window.label}\n${window.backlogLabel}',style:F.cap.copyWith(color:color,fontSize:12)),textDirection:TextDirection.ltr,textScaler:scaler,maxLines:2,ellipsis:'…')..layout(maxWidth:math.max(1,width-12));
    final labelLeft=math.max(left+6,math.min(edge+6,end-label.width-6));
    final labelTop=top+math.max(3,(base-top-label.height)/2);
    if(labelLeft<edge)canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(labelLeft-3,labelTop-2,label.width+6,label.height+4),const Radius.circular(4)),Paint()..color=p.card.withValues(alpha:.88));
    label.paint(canvas,Offset(labelLeft,labelTop));label.dispose();
    if(x(window.now)<=end){for(var y=top;y<base;y+=7){canvas.drawLine(Offset(now,y),Offset(now,math.min(y+3,base)),Paint()..color=p.ink3..strokeWidth=1);}}
    if(x(window.now)<=end){
      final marker=TextPainter(text:TextSpan(text:'now',style:F.cap.copyWith(color:p.ink3)),textDirection:TextDirection.ltr,textScaler:scaler)..layout();
      marker.paint(canvas,Offset(math.max(left,now-marker.width-3),top+2));marker.dispose();
    }
    canvas.restore();
  }
  @override bool shouldRepaint(SyncStripOverlayPainter old)=>true;
}
