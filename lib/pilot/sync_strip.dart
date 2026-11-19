// Owner: each SyncStripHome State owns its read snapshot and refresh timer.
import 'dart:async';
import 'dart:math' as math;
import 'package:clock/clock.dart';
import '../gestures/moment_follow_ups.dart';
import '../gestures/moment_review_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../data/day_label.dart';
import '../l10n/app_localizations.dart';
import '../models/activity_suggestion.dart';
import '../state/app_state.dart';
import '../state/clock_format.dart';
import '../ui2/ui2.dart';
import '../ui2/day_timeline/day_graph.dart';
import '../ui2/screens/home_screen.dart' show repoOf;
import '../ui2/screens/day_timeline.dart' show dayGraph;
import 'sync_strip_policy.dart';
export 'sync_strip_policy.dart';

SyncStripWindow syncStripWindow(BuildContext c, {DateTime? now, bool listen=true}) {
  final at=(now??clock.now()).millisecondsSinceEpoch~/1000;
  (int?,bool,int?) fields=(null,false,null);
  (int?,bool,int?) read(AppState app)=>(app.lastRecordAt==null?null:app.lastRecordAt!.millisecondsSinceEpoch~/1000,app.isConnected,app.device.dataRangeNewest);
  try { fields=listen?c.select<AppState,(int?,bool,int?)>(read):read(c.read<AppState>()); }
  on ProviderNotFoundException { /* Galleries have no band. */ }
  return SyncStripWindow(now:at,last:fields.$1,connected:fields.$2,reportedNewest:fields.$3);
}

String syncStripCaption({required String description,required int count,required TextStyle style,
  required double width,required TextScaler scaler,required TextDirection direction}) {
  final measure=TextPainter(text:TextSpan(text:description,style:style),textDirection:direction,textScaler:scaler,maxLines:1)..layout();
  final fits=measure.width<=width;measure.dispose();
  return fits||count==0?description:count==1?'1 item to review':'$count items to review';
}

double _actionHeight(BuildContext c,double width) {
  final style=DefaultTextStyle.of(c).style.merge(F.cap.copyWith(fontWeight:FontWeight.w600));
  var height=0.0;
  for(final label in [AppLocalizations.of(c)?.activityReview??'Review','View day']){
    final text=TextPainter(text:TextSpan(text:label,style:style),textDirection:Directionality.of(c),textScaler:MediaQuery.textScalerOf(c),maxLines:2)
      ..layout(maxWidth:math.max(1,width*.38-S.x3*2));
    height=math.max(height,text.height);text.dispose();
  }
  return math.max(48,height+S.x2*2+14);
}

class SyncStripRow extends StatelessWidget {
  const SyncStripRow({super.key,required this.window,required this.count,required this.onOpen,
    this.graphs=const [],this.pending=const [],this.moments=const [],this.reviewRanges=const [],this.description,this.failed=false});
  final SyncStripWindow window;
  final int count;
  final VoidCallback onOpen;
  final List<DayGraph> graphs;
  final List<ActivitySuggestion> pending;
  final List<int> moments;
  final List<(int,int)> reviewRanges;
  final String? description;
  final bool failed;
  @override Widget build(BuildContext c) {
    final p=P.of(c),review=count>0||failed;
    final l=AppLocalizations.of(c);
    final caption=failed?(l?.activityLoadFailed??'Could not load activities. Try again.'):description??(review?(count==1?'1 item to review':'$count items to review'):l?.homeBreakdownTitle??'Breakdown of your day');
    final color=review?C.domHome:C.n500;
    return Padding(padding:const EdgeInsets.only(bottom:S.x3),child:Surface(
      pad:const EdgeInsets.symmetric(horizontal:14,vertical:12),
      child:LayoutBuilder(builder:(c,box)=>Row(children:[
        Expanded(child:Stack(children:[
          Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
            Semantics(label:'$caption. ${window.statusLabel}.',excludeSemantics:true,
              child:SyncStripPlot(window:window,graphs:graphs,pending:pending,moments:moments,reviewRanges:reviewRanges)),
            Padding(padding:const EdgeInsets.only(right:32),child:LayoutBuilder(builder:(c,box){
              final style=DefaultTextStyle.of(c).style.merge(F.cap.copyWith(color:p.on(review?C.domHome:C.n500),fontSize:12,fontWeight:review?FontWeight.w600:FontWeight.w400)).copyWith(inherit:false);
              return ExcludeSemantics(child:Text(syncStripCaption(description:caption,count:failed?0:count,style:style,width:box.maxWidth,
                scaler:MediaQuery.textScalerOf(c),direction:Directionality.of(c)),maxLines:1,overflow:TextOverflow.ellipsis,style:style));
            })),
          ]),
          Positioned(right:0,bottom:0,width:48,height:48,child:IconButton(padding:EdgeInsets.zero,alignment:Alignment.bottomCenter,tooltip:'What is the faded part?',
            onPressed:()=>showSyncStripHelp(c,window),icon:Icon(Icons.help_outline,size:16,color:p.ink3))),
        ])),
        const SizedBox(width:12),
        Semantics(button:true,child:ConstrainedBox(constraints:BoxConstraints(maxWidth:box.maxWidth*.38),child:SizedBox(height:_actionHeight(c,box.maxWidth),child:Align(widthFactor:1,child:Pressable(onTap:onOpen,
          child:Padding(padding:const EdgeInsets.symmetric(vertical:7),child:Container(
            padding:const EdgeInsets.symmetric(horizontal:S.x3,vertical:S.x2),
            decoration:BoxDecoration(color:p.fill(color),borderRadius:R.rSm),
            child:Text(review?(l?.activityReview??'Review'):'View day',maxLines:2,textAlign:TextAlign.center,style:F.cap.copyWith(color:p.inkOnFill,fontWeight:FontWeight.w600))))))))),
    ]))));
  }
}

Future<void> showSyncStripHelp(BuildContext c,SyncStripWindow window) => showModalBottomSheet<void>(
  context:c,showDragHandle:true,sheetAnimationStyle:Motion.enabled(c)?null:AnimationStyle.noAnimation,backgroundColor:P.of(c).card2,isScrollControlled:true,
  builder:(c){final p=P.of(c);return SafeArea(child:SingleChildScrollView(child:Padding(padding:const EdgeInsets.fromLTRB(20,0,20,20),child:Column(
    mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Text(window.reported?'Still on your band':'Maybe on your band',style:F.head.copyWith(color:p.ink)),
      const SizedBox(height:8),Text(window.reported
        ?'Your band sends its data to your phone in batches. The faded part is what the band says it is still holding. ${window.backlogLabel}'
        :"Your phone has no usable report of what your band is holding. The faded part marks the time since the last synced record. There may be data here, or the band may have been off your wrist.",style:F.body.copyWith(color:p.ink2)),
      const SizedBox(height:12),
      for(final item in [(C.red,'Heart rate the phone has'),(window.reported?C.domHome:C.n500,'Not synced yet'),(C.domHome,'Waiting for review')])
        Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(children:[Container(width:28,height:item.$2=='Waiting for review'?3:12,color:p.on(item.$1).withValues(alpha:.5)),const SizedBox(width:10),Expanded(child:Text(item.$2,style:F.cap.copyWith(color:p.ink2)))])),
      const SizedBox(height:14),BigButton('Got it',onTap:()=>Navigator.of(c).pop()),
    ]))));});

class SyncStripHome extends StatefulWidget {
  const SyncStripHome({super.key,required this.count,required this.onOpen,this.failed=false});
  final int count;final bool failed;final ValueChanged<bool> onOpen;
  @override State<SyncStripHome> createState()=>_SyncStripHomeState();
}
class _SyncStripHomeState extends State<SyncStripHome> with RevisionReload {
  List<DayGraph> _graphs=[];List<ActivitySuggestion> _pending=[];
  bool _failed=false,_reading=false,_loaded=false,_reloadAgain=false;
  List<int> _moments=[];
  List<(int,int)> _ranges=[];
  int _markedCount=0,_waterCount=0;
  int? _edge;Timer? _timer;
  @override void initState(){super.initState();_timer=Timer.periodic(const Duration(minutes:1),(_){if(mounted){setState((){});reload();}});}
  @override void didChangeDependencies(){super.didChangeDependencies();final edge=syncStripWindow(context,listen:false).last;final minute=edge==null?null:edge~/60;if(minute!=_edge||!_loaded){_edge=minute;_loaded=true;reload();}}
  @override void dispose(){_timer?.cancel();super.dispose();}
  @override void reload(){unawaited(_load());}
  Future<void> _load()async{
    if(_reading){_reloadAgain=true;return;}
    final repo=repoOf(context);if(repo==null)return;
    _reading=true;
    try{
      final window=syncStripWindow(context,now:clock.now(),listen:false);
      final start=DateTime.fromMillisecondsSinceEpoch(window.start*1000);
      final end=DateTime.fromMillisecondsSinceEpoch((window.last??window.now)*1000);
      final graphs=<DayGraph>[];
      for(var date=DateTime(start.year,start.month,start.day);!date.isAfter(end);date=DateTime(date.year,date.month,date.day+1)){
        graphs.add(dayGraph(await repo.getDayTimeline(dayLabelOf(date))));
      }
      final pending=await repo.pendingActivities();
      if(!mounted)return;
      final moments=<int>[],ranges=<(int,int)>[];
      var markedCount=0,waterCount=0;
      try {
        final settings=context.read<AppState>().gestureSettings;
        if(settings.followUpMoments){
          final followups=await MomentFollowUps.load(enabledSince:settings.followUpMomentsSince);
          final marks=followups.pending(clock.now());
          moments.addAll(marks.where((m)=>!m.ambiguous).map((m)=>m.sec));
          final water=followups.pendingAssumed(clock.now());
          moments.addAll(water.where((g)=>!wallMinuteIsAmbiguous(g.local)).map((g)=>g.local.millisecondsSinceEpoch~/1000));
          final reviews=MomentReviewService.shared..reload();
          final orphaned=reviews.queue.orphanRanges(marks.map((m)=>m.key).toSet());
          ranges.addAll([for(final range in orphaned)if(range.startSec!=null&&range.endSec!=null)(range.startSec!,range.endSec!)]);
          markedCount=marks.length+orphaned.length;waterCount=water.length;
        }
      } on ProviderNotFoundException { /* No band in a gallery. */ }
      if(mounted)setState((){_graphs=graphs;_pending=pending;_moments=moments;_ranges=ranges;_markedCount=markedCount;_waterCount=waterCount;_failed=false;});
    }catch(_){if(mounted)setState(()=>_failed=true);}
    finally{_reading=false;if(_reloadAgain&&mounted){_reloadAgain=false;reload();}}
  }
  @override Widget build(BuildContext c){
    final window=syncStripWindow(c);
    final minute=window.last==null?null:window.last!~/60;
    if(minute!=_edge){_edge=minute;scheduleMicrotask((){if(mounted)reload();});}
    final names=<String>[];
    final counts=<String,int>{};
    for(final s in _pending){final kind=switch(s.kind){ActivityKind.nap=>'nap',ActivityKind.workout=>s.sport=='walking'||s.sport=='walk'?'walk':'workout',ActivityKind.meal=>'meal',ActivityKind.track=>'activity'};counts[kind]=(counts[kind]??0)+1;}
    for(final entry in counts.entries){names.add(entry.value==1?'${entry.key=='activity'?'an':'a'} ${entry.key}':'${entry.value} ${entry.key}s');}
    var extra=widget.count-_pending.length;
    if(_markedCount>0&&_markedCount<=extra){names.add(_markedCount==1?'a moment':'$_markedCount moments');extra-=_markedCount;}
    if(_waterCount>0&&_waterCount<=extra){names.add(_waterCount==1?'a glass of water':'$_waterCount glasses of water');extra-=_waterCount;}
    if(extra>0)names.add(extra==1?'an item':'$extra items');
    String? description;
    if(names.isNotEmpty&&widget.count>=_pending.length){final joined=names.length<2?names.first:'${names.take(names.length-1).join(', ')} and ${names.last}';description='${joined[0].toUpperCase()}${joined.substring(1)} to review';}
    return SyncStripRow(window:window,count:widget.count,graphs:_graphs,pending:_pending,moments:_moments,reviewRanges:_ranges,
      description:description,failed:widget.failed||_failed,onOpen:()=>widget.onOpen(widget.count>0||widget.failed||_failed));
  }
}

class SyncStripPlot extends StatelessWidget {
  const SyncStripPlot({super.key,required this.window,this.graphs=const [],this.pending=const [],this.moments=const [],this.reviewRanges=const []});
  final List<(int,int)> reviewRanges;
  final SyncStripWindow window;
  final List<DayGraph> graphs;final List<ActivitySuggestion> pending;final List<int> moments;
  @override Widget build(BuildContext c)=>LayoutBuilder(builder:(c,box){
    final p=P.of(c),scaler=MediaQuery.textScalerOf(c);
    final style=DefaultTextStyle.of(c).style.merge(F.cap.copyWith(color:p.on(window.reported?C.domHome:C.n500))).copyWith(inherit:false);
    String label='';double labelWidth=0;
    if(window.missing>0){
      for(final candidate in [window.label,window.reported?'On band':'Maybe on band','?','']){
        final measure=TextPainter(text:TextSpan(text:candidate,style:style),textDirection:Directionality.of(c),textScaler:scaler,maxLines:1)..layout();
        final width=measure.width.ceilToDouble();measure.dispose();
        if(width+12<=box.maxWidth||candidate.isEmpty){label=candidate;labelWidth=width;break;}
      }
    }
    final real=window.missing==0?box.maxWidth:math.max(0.0,math.min(box.maxWidth*window.realFraction,box.maxWidth-labelWidth-12));
    final height=math.max(44.0,scaler.scale(F.cap.fontSize!)*1.5+14);
    return SizedBox(height:height,child:Stack(children:[
      Positioned.fill(child:CustomPaint(painter:SyncStripPainter(p:p,window:window,graphs:graphs,pending:pending,moments:moments,reviewRanges:reviewRanges,realWidth:real))),
      if(label.isNotEmpty)Positioned(left:real+6,right:6,top:0,bottom:13,child:Center(child:Text(label,key:const ValueKey('sync-strip-band-label'),style:style,maxLines:1,overflow:TextOverflow.clip))),
    ]));
  });
}

class SyncStripPainter extends CustomPainter {
  SyncStripPainter({required this.p,required this.window,this.graphs=const [],this.pending=const [],this.moments=const [],this.reviewRanges=const [],this.realWidth});
  final List<(int,int)> reviewRanges;
  final double? realWidth;
  final P p;final SyncStripWindow window;final List<DayGraph> graphs;final List<ActivitySuggestion> pending;final List<int> moments;
  @override void paint(Canvas canvas,Size size){
    final real=realWidth??size.width*window.realFraction,bottom=size.height-13;
    double x(num at)=>(at-window.start)/window.realSeconds*real;
    canvas.save();canvas.clipRect(Rect.fromLTWH(0,0,real,bottom));
    for(final g in graphs){final base=g.dayStart;if(base==null)continue;
      for(final span in [...g.rest,...g.work]){canvas.drawRect(Rect.fromLTRB(x(base+span.$1*60),2,x(base+span.$2*60),bottom),Paint()..color=p.on(span.$3).withValues(alpha:.12));}
      Offset? previous;
      for(var i=0;i<g.hr.length;i+=5){
        final at=base+i*60;if(at> (window.last??window.now)||at<window.start){previous=null;continue;}
        final samples=g.hr.skip(i).take(math.min(5,((window.last??window.now)-at)~/60+1)).whereType<double>().where((v)=>v.isFinite&&v>0).toList();
        if(samples.isEmpty){previous=null;continue;}
        final avg=samples.reduce((a,b)=>a+b)/samples.length;
        final point=Offset(x(at),bottom-3-((avg-40)/100).clamp(0,1)*(bottom-7));
        if(previous!=null)canvas.drawLine(previous,point,Paint()..color=p.on(C.red).withValues(alpha:.45*(window.missing>0?(1-(point.dx/math.max(1,real)).clamp(0,1)*.8):1))..strokeWidth=1.5);
        previous=point;
      }
    }
    for(final s in pending){if(s.isPrompt)continue;canvas.drawLine(Offset(x(s.startTs),bottom-2),Offset(math.max(x(s.startTs)+3,x(s.endTs)),bottom-2),Paint()..color=p.on(C.domHome)..strokeWidth=2.5);}
    for(final (start,end) in reviewRanges){canvas.drawLine(Offset(x(start),bottom-2),Offset(math.max(x(start)+3,x(end)),bottom-2),Paint()..color=p.on(C.domHome)..strokeWidth=2.5);}
    for(final at in moments){canvas.drawLine(Offset(x(at)-1,bottom-2),Offset(x(at)+2,bottom-2),Paint()..color=p.on(C.domHome)..strokeWidth=2.5);}
    canvas.restore();
    canvas.drawLine(Offset(0,bottom),Offset(size.width,bottom),Paint()..color=p.ink3.withValues(alpha:.2));
    if(window.missing>0){paintSyncFade(canvas,Rect.fromLTRB(real-(size.width-real)*.25,2,size.width,bottom),p,'',reported:window.reported);
      if(window.compressed)_text(canvas,'≈',Offset(real,size.height-12),p.ink3,10);}
    _text(canvas,formatClockOf(DateTime.fromMillisecondsSinceEpoch(window.start*1000)),Offset(0,size.height-12),p.ink3,10);
    _text(canvas,'now',Offset(size.width-22,size.height-12),p.ink3,10);
  }
  @override bool shouldRepaint(SyncStripPainter old)=>true;
}

void _text(Canvas canvas,String label,Offset at,Color color,double font,{double? width}){
  final t=TextPainter(text:TextSpan(text:label,style:F.cap.copyWith(color:color,fontSize:font)),textDirection:TextDirection.ltr,maxLines:2)..layout(maxWidth:width??double.infinity);
  t.paint(canvas,at);t.dispose();
}
void paintSyncFade(Canvas canvas,Rect rect,P p,String label,{bool reported=false}){
  if(rect.width<=0)return;
  final color=p.on(reported?C.domHome:C.n500);
  canvas.drawRRect(RRect.fromRectAndRadius(rect,const Radius.circular(6)),Paint()..shader=LinearGradient(colors:[color.withValues(alpha:0),color.withValues(alpha:.16),color.withValues(alpha:.10)],stops:const [0,.35,1]).createShader(rect));
  _text(canvas,label,Offset(rect.left+rect.width*.2,rect.top+rect.height*.3),color,10,width:rect.width*.8);
}
