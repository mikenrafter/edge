import '../ui2/charts.dart' show SleepStage;

/// Projects only stored segments. Unknown labels and uncovered epochs stay absent.
List<SleepStage?> recordedStages(Map<String,dynamic> night,{required int origin,required int slots,int shiftSeconds=0}){
  final out=List<SleepStage?>.filled((slots/5).ceil(),null),points=night['hypnogram'];
  if(points is! List)return out;
  for(var i=0;i+1<points.length;i++){
    final a=points[i],b=points[i+1];
    if(a is! Map||b is! Map||a['t'] is! num||b['t'] is! num)continue;
    final from=(a['t'] as num).toInt()+shiftSeconds,to=(b['t'] as num).toInt()+shiftSeconds;
    final stage=switch(a['stage']){'wake'||'awake'=>SleepStage.awake,'rem'=>SleepStage.rem,'deep'=>SleepStage.deep,'light'||'nrem'=>SleepStage.light,_=>null};
    if(to<=from)continue;
    for(var k=((from-origin)/300).floor().clamp(0,out.length);k<((to-origin)/300).ceil().clamp(0,out.length);k++)out[k]=stage;
  }
  return out;
}
