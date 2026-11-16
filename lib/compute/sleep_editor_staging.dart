// Owner: the day worker applies explicit nap staging requests. Reuses the
// canonical forced-window sleep segmentation; never detects replacement bounds.
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../data/day_label.dart';
import '../util/heavy.dart';
import 'nap_edits.dart';
import 'substrate.dart';

// CLAIM(sleep-editor-stages-only): absent input abstains, and the requested
// interval is retained exactly [sleep_editor_staging_test]. Runs in the day worker.
@heavy
List<NapEdit> restageEditorNapsHeavy(Substrate sub, List<NapEdit> edits,
    {ana.StagingMethod method = ana.StagingMethod.cardio}) => [
  for (final edit in edits)
    if (edit.kind == NapEditKind.added && edit.snapshot?['_stage_only'] == true)
      NapEdit(kind:edit.kind,startSec:edit.startSec,endSec:edit.endSec,
        snapshot:_stageHeavy(sub,edit,method))
    else edit,
];

@heavy
Map<String,dynamic> _stageHeavy(Substrate sub, NapEdit edit, ana.StagingMethod method) {
  final day=dayLabelOf(DateTime.fromMillisecondsSinceEpoch((edit.endSec-1)*1000));
  final days=calendarDays(sub,method:method,targetDay:day,skipUnusedDays:true,
    override:SleepWindowOverride(dayId:day,onsetSec:edit.startSec,
      offsetSec:edit.endSec,source:'confirmed'));
  final sleep=days.where((d)=>d.date==day).firstOrNull?.sleep;
  final labels=sleep?.stages4 ?? const <String>[];
  final hypnogram=<Map<String,dynamic>>[];
  var i=0;
  while(i<labels.length){
    final stage=labels[i];var end=i+1;
    while(end<labels.length && labels[end]==stage){end++;}
    if(stage!='unobserved') { hypnogram.add({'start':edit.startSec+i,
      'end':edit.startSec+end,'stage':stage}); }
    i=end;
  }
  return {...?edit.snapshot,'start':edit.startSec,'end':edit.endSec,
    '_staged_bounds':[edit.startSec,edit.endSec],
    'duration_min':sleep?.tstSec == null ? null : (sleep!.tstSec!/60).round(),
    'in_bed_min':(edit.endSec-edit.startSec)/60,
    'deep_min':sleep?.deepSec == null ? null : sleep!.deepSec!/60,
    'rem_min':sleep?.remSec == null ? null : sleep!.remSec!/60,
    'light_min':sleep?.lightSec == null ? null : sleep!.lightSec!/60,
    'efficiency':sleep?.efficiencyPct == null ? null : sleep!.efficiencyPct!/100,
    'hypnogram':hypnogram.isEmpty ? null : hypnogram,
  };
}
