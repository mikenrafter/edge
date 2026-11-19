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

/// Text stays inside the visible band; the right axis has its own column.
class SyncBandLabelLayout {
  const SyncBandLabelLayout(this.text,this.bounds,this.nowBounds);
  final String text;
  final Rect bounds,nowBounds;
}
SyncBandLabelLayout syncBandLabelLayout({required SyncStripWindow window,required Rect band,
  required double plotLeft,required double axisLeft,required TextStyle style,required TextScaler scaler}) {
  final seconds=window.reported?window.reportedNewest!-window.last!:window.missing;
  final shortTime=window.reported?bandDuration(seconds):'${bandDuration(seconds)} ago';
  final maxWidth=math.max(0.0,math.min(band.width-12,2*(axisLeft-6-band.center.dx)));
  final marker=TextPainter(text:TextSpan(text:'now',style:style),textDirection:TextDirection.ltr,textScaler:scaler,maxLines:1)..layout();
  final markerRight=math.max(plotLeft+marker.width,math.min(band.right,axisLeft-6));
  final nowBounds=Rect.fromLTWH(markerRight-marker.width,math.max(0,band.top-marker.height-2),marker.width,marker.height);
  final maxHeight=math.min(band.height-8,2*(band.center.dy-math.max(band.top+4,nowBounds.bottom+4)));
  var text='';var bounds=Rect.fromCenter(center:band.center,width:0,height:0);
  for(final candidate in ['${window.label}\n${window.backlogLabel}',
    '${window.reported?'On band':'Maybe on band'}\n$shortTime','?\n$shortTime','?','']){
    final measure=TextPainter(text:TextSpan(text:candidate,style:style),textDirection:TextDirection.ltr,textScaler:scaler,maxLines:2)..layout();
    if(measure.width.ceilToDouble()<=maxWidth&&measure.height<=maxHeight){
      text=candidate;bounds=Rect.fromCenter(center:band.center,width:measure.width,height:measure.height);measure.dispose();break;
    }
    measure.dispose();
  }
  marker.dispose();return SyncBandLabelLayout(text,bounds,nowBounds);
}

/// Uses the chart's own time mapping; the day chart keeps its gestures and axes.
class SyncStripOverlay extends StatefulWidget {
  const SyncStripOverlay({super.key,required this.view,this.left=0,this.right=0,this.top=20,this.bottom=24,this.window,this.axisRight=0,this.axes});
  final TimelineView view;
  final double left,right,top,bottom,axisRight;
  final CustomPainter? axes;
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
    return IgnorePointer(child:Semantics(label:'${window.label}. ${window.backlogLabel}',child:CustomPaint(foregroundPainter:widget.axes,
      painter:SyncStripOverlayPainter(p:P.of(c),view:widget.view,window:window,left:widget.left,right:widget.right,top:widget.top,bottom:widget.bottom,
        scaler:MediaQuery.textScalerOf(c),axisRight:widget.axisRight))));
  });
}
class SyncStripOverlayPainter extends CustomPainter {
  SyncStripOverlayPainter({required this.p,required this.view,required this.window,this.left=0,this.right=0,this.top=20,this.bottom=24,this.scaler=TextScaler.noScaling,this.axisRight=0});
  final P p;final TimelineView view;final SyncStripWindow window;
  final double left,right,top,bottom,axisRight;final TextScaler scaler;
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
    final style=F.cap.copyWith(color:color);
    final layout=syncBandLabelLayout(window:window,band:Rect.fromLTRB(edge,top,now,base),plotLeft:left,axisLeft:end-axisRight,style:style,scaler:scaler);
    if(layout.text.isNotEmpty){
      final label=TextPainter(text:TextSpan(text:layout.text,style:style),textDirection:TextDirection.ltr,textScaler:scaler,maxLines:2)..layout();
      label.paint(canvas,layout.bounds.topLeft);label.dispose();
    }
    if(x(window.now)<=end){for(var y=top;y<base;y+=7){canvas.drawLine(Offset(now,y),Offset(now,math.min(y+3,base)),Paint()..color=p.ink3..strokeWidth=1);}}
    canvas.restore();
    if(x(window.now)<=end){
      final marker=TextPainter(text:TextSpan(text:'now',style:F.cap.copyWith(color:p.ink3)),textDirection:TextDirection.ltr,textScaler:scaler,maxLines:1)..layout();
      marker.paint(canvas,layout.nowBounds.topLeft);marker.dispose();
    }
  }
  @override bool shouldRepaint(SyncStripOverlayPainter old)=>true;
}
