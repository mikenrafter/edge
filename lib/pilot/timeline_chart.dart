// Owner: each PilotTimelineChart State owns pointer timers; its controller owns time.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../l10n/app_localizations.dart';
import '../state/clock_format.dart' show formatClockOf;
import '../ui2/chart_annotations.dart';
import '../ui2/charts.dart' show SleepStage, Hypnogram;
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/day_timeline/timeline_controller.dart';
import '../ui2/theme.dart';
import 'timeline_policy.dart';

String pilotClock(double sec) => formatClockOf(DateTime.fromMillisecondsSinceEpoch(sec.round()*1000));

class PilotHandle {
  const PilotHandle(this.id,this.at,this.color,{this.active=true});
  final String id;
  final double at;
  final Color color;final bool active;
}

class PilotTimelineChart extends StatefulWidget {
  const PilotTimelineChart({super.key,required this.controller,required this.graph,
    required this.interaction,this.annotations=const [],this.stages=const [],
    this.handles=const [],this.onHandle,this.onSelect,this.onScrub,this.onPan,
    this.onTapTime,this.height=112,this.dimHrInsideSleep=true});
  final TimelineController controller;
  final DayGraph graph;
  final TimelineInteraction interaction;
  final List<ChartAnnotation> annotations;
  final List<SleepStage?> stages;
  final List<PilotHandle> handles;
  final void Function(String,double)? onHandle;
  final ValueChanged<String>? onSelect;
  final ValueChanged<double>? onScrub,onPan,onTapTime;
  final double height;
  final bool dimHrInsideSleep;
  @override State<PilotTimelineChart> createState()=>_PilotChartState();
}

class _PilotChartState extends State<PilotTimelineChart> with TickerProviderStateMixin {
  Timer? _hold,_fineTimer,_edge;
  Offset? _down,_position;
  TimelineView? _panStart;
  bool _scrub=false,_fine=false,_moved=false;
  String? _handle;
  double _width=1;
  double? _zoomStart;int _edgeDirection=0,_edgeTicks=0;
  TimelineController get c=>widget.controller;
  TimelineInteraction get interaction=>widget.interaction;
  double _time(double dx)=>c.view.at((dx/_width).clamp(0,1));
  @override void didChangeDependencies(){super.didChangeDependencies();c.attach(this,reducedMotion:!Motion.enabled(context));}
  @override void didUpdateWidget(PilotTimelineChart old){super.didUpdateWidget(old);if(old.controller!=c){old.controller.detach(this);c.attach(this,reducedMotion:!Motion.enabled(context));}}
  @override void dispose(){_hold?.cancel();_fineTimer?.cancel();_edge?.cancel();c.detach(this);super.dispose();}
  void _start(PointerDownEvent e){
    _down=_position=e.localPosition;_panStart=c.view;_moved=false;_fine=false;_scrub=false;_handle=null;
    if(c.selection!=null){_zoomStart=_time(e.localPosition.dx);return;}
    var nearest=25.0;for(final h in widget.handles){final distance=(c.view.fraction(h.at)*_width-e.localPosition.dx).abs();if(distance<nearest){_handle=h.id;nearest=distance;}}
    _hold=Timer(const Duration(milliseconds:300),(){
      if(!mounted||_down==null||_moved)return;
      if(_handle==null){_scrub=true;_setCursor(_time(_position!.dx));}
      HapticFeedback.selectionClick();setState((){});
    });
    _fineTimer=Timer(const Duration(milliseconds:600),(){
      if(!mounted||_down==null||_moved)return;
      _fine=true;HapticFeedback.mediumImpact();setState((){});
    });
    _edge=Timer.periodic(const Duration(milliseconds:16),(_){
      if(_down==null||(!_scrub&&_handle==null)||_position==null)return;
      final x=_position!.dx;
      final depth=x<40?-(40-x)/40:x>_width-40?(x-(_width-40))/40:0.0;
      if(depth.sign.toInt()!=_edgeDirection){_edgeDirection=depth.sign.toInt();_edgeTicks=0;}
      if(depth==0)return;
      final held=++_edgeTicks*16;if(held<300)return;
      _fine=false;_fineTimer?.cancel();
      c.panBy(depth.sign*depth.abs().clamp(0,1)*depth.abs().clamp(0,1)*c.view.span*.5*.016*((held-300)/400).clamp(0,1));
      _edit(_time(x));
    });
  }
  void _setCursor(double at){
    final step=_fine?60:300;
    final snapped=(at/step).round()*step.toDouble();
    if(c.scrub!=snapped)HapticFeedback.selectionClick();
    interaction.startScrub(snapped);c.setScrub(snapped);widget.onScrub?.call(snapped);
  }
  void _edit(double at){
    if(_handle!=null){
      final step=_fine?60:300;
      widget.onHandle?.call(_handle!,(at/step).round()*step.toDouble());
    } else if(_scrub){_setCursor(at);}
  }
  void _move(PointerMoveEvent e){
    if(_down==null)return;_position=e.localPosition;
    if(c.selection!=null&&_zoomStart!=null){c.updatePilotSelection(_zoomStart!,_time(e.localPosition.dx));return;}
    final delta=e.localPosition-_down!;
    if(delta.distance>6){_moved=true;_hold?.cancel();}
    if(_scrub||_handle!=null){_edit(_time(e.localPosition.dx));}
    else if(_moved){
      c.panTo(_panStart!.start-delta.dx/_width*_panStart!.span);
      widget.onPan?.call(c.view.center);
    }
  }
  void _end(PointerEvent e){
    _hold?.cancel();_fineTimer?.cancel();_edge?.cancel();
    if(e is! PointerCancelEvent){
      if(_zoomStart!=null){c.finishPilotSelection();interaction.zoom();}
      else if(!_moved&&_handle!=null){widget.onSelect?.call(_handle!);}
      else if(!_moved&&!_scrub&&_handle==null){
        final at=_time(e.localPosition.dx);widget.onTapTime?.call(at);
        ChartAnnotation? nearest;
        for(final a in widget.annotations){if(nearest==null||(a.at-at).abs()<(nearest.at-at).abs())nearest=a;}
        if(nearest!=null&&(nearest.at-at).abs()<c.view.span*.05)widget.onSelect?.call(nearest.id);
      }
    }
    interaction.lift();
    if(interaction.retention==PilotScrub.temporary)c.clearScrub();
    _down=null;_handle=null;_zoomStart=null;_scrub=false;_fine=false;
    if(mounted)setState((){});
  }
  @override Widget build(BuildContext context){
    final p=P.of(context),l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    return RepaintBoundary(child:ListenableBuilder(
      listenable:Listenable.merge([c.range,c.scrubChanges,c.zoomChanges,interaction]),
      builder:(context,_)=>LayoutBuilder(builder:(context,box){
        _width=box.maxWidth;
        final visible=widget.annotations.where((a)=>a.at<=c.view.end&&(a.until??a.at)>=c.view.start).toList();
        final lanes=<double>[];final marks=<({ChartAnnotation annotation,double x,int lane})>[];
        for(final a in visible){
          final x=(c.view.fraction(a.at)*_width).clamp(12.0,math.max(12.0,_width-12)).toDouble();
          var lane=0;while(lane<lanes.length&&(lanes[lane]-x).abs()<24)lane++;
          if(lane==lanes.length)lanes.add(x);else lanes[lane]=x;
          marks.add((annotation:a,x:x,lane:lane));
        }
        ChartAnnotation? nearest;
        for(final a in visible){if(nearest==null||(a.at-(c.scrub??c.view.center)).abs()<(nearest.at-(c.scrub??c.view.center)).abs())nearest=a;}
        return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          SizedBox(height:26,child:Row(children:[Expanded(child:Text(nearest?.label??'',maxLines:1,overflow:TextOverflow.ellipsis,style:F.cap.copyWith(color:p.ink2))),Text('bpm',style:F.cap.copyWith(color:p.on(C.red)))])),
          Listener(onPointerDown:_start,onPointerMove:_move,onPointerUp:_end,onPointerCancel:_end,
            child:GestureDetector(onPanUpdate:(_){},behavior:HitTestBehavior.opaque,
              child:SizedBox(key:const ValueKey('pilot-timeline-plot'),height:widget.height+24,
                child:ClipRect(child:Stack(children:[
                  Positioned.fill(child:CustomPaint(painter:_PilotPainter(p:p,view:c.view,graph:widget.graph,stages:widget.stages,
                    annotations:visible,scrub:c.scrub,selection:c.selection,height:widget.height,dimHrInsideSleep:widget.dimHrInsideSleep))),
                  for(final mark in marks)Positioned(left:mark.x-12,top:mark.lane*22.0,child:Tooltip(message:mark.annotation.label,
                    child:Icon(mark.annotation.icon??annotationIcon(mark.annotation.kind),size:18,color:p.on(annotationColor(mark.annotation.kind))))),
                  if(c.selection==null)for(final h in widget.handles)if(h.at>=c.view.start&&h.at<=c.view.end)
                    Positioned(left:c.view.fraction(h.at)*_width-24,top:22,width:48,height:math.max(48,widget.height-24),
                      child:IgnorePointer(child:Center(child:Container(width:h.active?6:2,height:widget.height-28,decoration:BoxDecoration(color:h.color.withValues(alpha:h.active?1:.35),borderRadius:BorderRadius.circular(3))))),),
                  Positioned(right:6,bottom:30,child:IgnorePointer(child:Opacity(opacity:.65,child:Text(_fine?l.pilotFineSteps:_scrub?l.pilotScrubbing:l.pilotHoldScrub,style:F.cap.copyWith(color:p.ink2))))),
                ]))))),
        ]);
      })));
  }
}

class _PilotPainter extends CustomPainter {
  _PilotPainter({required this.p,required this.view,required this.graph,required this.stages,
    required this.annotations,required this.scrub,required this.selection,required this.height,required this.dimHrInsideSleep});
  final P p; final TimelineView view; final DayGraph graph; final List<SleepStage?> stages;
  final List<ChartAnnotation> annotations;final double? scrub;final TimelineView? selection;final double height;
  final bool dimHrInsideSleep;
  @override void paint(Canvas canvas,Size size){
    final w=size.width,base=(graph.dayStart??view.start).toDouble();
    double x(double at)=>view.fraction(at)*w;
    void text(String s,double dx,double dy,Color color,{bool right=false}){
      final t=TextPainter(text:TextSpan(text:s,style:F.cap.copyWith(color:color,fontSize:10)),textDirection:TextDirection.ltr,maxLines:1)..layout();
      t.paint(canvas,Offset(right?dx-t.width:dx,dy));t.dispose();
    }
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0,0,w,height),const Radius.circular(10)),Paint()..color=p.card);
    for(final gap in graph.unmeasured){
      canvas.drawRect(Rect.fromLTRB(x(base+gap.$1*60),20,x(base+gap.$2*60),height),Paint()..color=p.card2);
    }
    final ticks=visibleHeartRateTicks(graph.hr,start:((view.start-base)/60).floor(),end:((view.end-base)/60).ceil());
    final low=ticks.isEmpty?0:ticks.first,high=ticks.isEmpty?1:ticks.last;
    double y(num v)=>25+(1-(v-low)/(high-low))*(height-35);
    for(final t in ticks){
      for(var a=0.0;a<w;a+=8){canvas.drawLine(Offset(a,y(t)),Offset(math.min(a+3,w),y(t)),Paint()..color=p.on(C.red).withValues(alpha:.18));}

    }
    canvas.save();canvas.clipRect(Rect.fromLTWH(0,20,w,height-20));
    for(final a in annotations){
      final color=p.on(annotationColor(a.kind));
      if(a.until!=null)canvas.drawRect(Rect.fromLTRB(x(a.at),20,x(a.until!),height),Paint()..color=color.withValues(alpha:.09));
      for(final at in [a.at,if(a.until!=null)a.until!])for(var top=22.0;top<height;top+=7){canvas.drawLine(Offset(x(at),top),Offset(x(at),top+3),Paint()..color=color.withValues(alpha:.4));}
    }
    final colors=Hypnogram.cols(p);
    for(var i=0;i<stages.length;i++){
      final st=stages[i];if(st==null)continue;
      final left=x(base+i*300),right=x(base+(i+1)*300);
      if(right<0||left>w)continue;
      final depth=switch(st){SleepStage.awake=>0,SleepStage.rem=>1,SleepStage.light=>2,SleepStage.deep=>3};
      canvas.drawRect(Rect.fromLTRB(left,28+depth*(height-38)/4,right,28+(depth+1)*(height-38)/4-2),Paint()..color=colors[st]!.withValues(alpha:.5));
    }
    Offset? previous;
    for(var i=math.max(0,((view.start-base)/60).floor()-1);i<graph.hr.length&&base+i*60<=view.end+60;i++){
      final value=graph.hr[i];if(value==null||!value.isFinite||value<=0){previous=null;continue;}
      final point=Offset(x(base+i*60),y(value));
      final asleep=graph.rest.any((s)=>i>=s.$1&&i<s.$2);
      if(previous!=null)canvas.drawLine(previous,point,Paint()..color=p.on(C.red).withValues(alpha:asleep && dimHrInsideSleep ? .38 : .75)..strokeWidth=1.4);
      previous=point;
    }
    for(var i=math.max(0,((view.start-base)/60).floor());i<graph.movement.length&&base+i*60<view.end;i++){
      final v=graph.movement[i];if(v==null||!v.isFinite)continue;
      canvas.drawRect(Rect.fromLTRB(x(base+i*60),height-v.clamp(0,1)*(height-25)*.32,x(base+(i+1)*60),height),Paint()..color=p.on(C.purple).withValues(alpha:.75));
    }
    if(selection!=null)canvas.drawRect(Rect.fromLTRB(x(selection!.start),0,x(selection!.end),height),Paint()..color=p.on(C.blue).withValues(alpha:.2));
    if(scrub!=null)canvas.drawLine(Offset(x(scrub!),0),Offset(x(scrub!),height),Paint()..color=p.ink..strokeWidth=1.5);
    canvas.restore();
    for(final t in ticks)text('$t',w-3,y(t)-11,p.on(C.red),right:true);
    for(var i=0;i<=4;i++)text(pilotClock(view.at(i/4)),i==4?w:i*w/4,height+5,p.ink3,right:i==4);
  }
  @override bool shouldRepaint(_PilotPainter old)=>true;
}

class PilotZoomControls extends StatelessWidget {
  const PilotZoomControls({super.key,required this.controller,this.trailing,this.onZoom});
  final TimelineController controller;final Widget? trailing;final VoidCallback? onZoom;
  @override Widget build(BuildContext context){
    final l=AppLocalizations.of(context)??lookupAppLocalizations(const Locale('en'));
    final buttonStyle=TextButton.styleFrom(minimumSize:const Size(48,48),padding:const EdgeInsets.symmetric(horizontal:4));
    return ListenableBuilder(listenable:controller.zoomChanges,builder:(context,_)=>Row(children:[
      Expanded(child:TextButton.icon(style:buttonStyle,onPressed:(){onZoom?.call();controller.beginPilotSelection();},icon:const Icon(LucideIcons.zoomIn,size:16),label:Text(l.timelineZoomIn,maxLines:1,overflow:TextOverflow.ellipsis))),
      Expanded(child:TextButton.icon(style:buttonStyle,onPressed:controller.zoomed||controller.selection!=null?(){onZoom?.call();controller.resetZoom();}:null,icon:const Icon(LucideIcons.rotateCcw,size:16),label:Text(l.pilotZoomOut,maxLines:1,overflow:TextOverflow.ellipsis))),
      if(trailing!=null)Expanded(child:trailing!),
    ]));
  }
}
