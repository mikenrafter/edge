// WHY: selected staging must reuse the canonical forced-window stager, never
// publish guessed stages without samples, and leave other naps alone.
// CLAIM(sleep-editor-stages-only).
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/nap_edits.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/compute/sleep_editor_staging.dart';
import 'package:openstrap_edge/compute/accepted_naps.dart';

void main(){
  test('absent raw clears stage guesses while retaining exact requested bounds and unrelated entries',(){
    const target=NapEdit(kind:NapEditKind.added,startSec:1000,endSec:2800,
      snapshot:{'_stage_only':true,'duration_min':30,'deep_min':20,'hypnogram':[{'stage':'deep'}]});
    const other=NapEdit(kind:NapEditKind.added,startSec:5000,endSec:6200,
      snapshot:{'source':'legacy','duration_min':17});
    final out=restageEditorNapsHeavy(Substrate.empty,[target,other]);
    expect(out[0].snapshot!['start'],1000);
    expect(out[0].snapshot!['end'],2800);
    expect(out[0].snapshot!['duration_min'],isNull);
    expect(out[0].snapshot!['deep_min'],isNull);
    expect(out[0].snapshot!['hypnogram'],isNull);
    expect(identical(out[1],other),isTrue);
  });
  test('measured nap stages cover the selected bounds exactly using the canonical stager',(){
    final t=DateTime(2026,11,14,1).millisecondsSinceEpoch~/1000;
    final sub=Substrate(tsSec:[for(var i=0;i<3600;i++)t+i],hr:List.filled(3600,55),
      rrTsMs:[for(var i=0;i<3500;i++)(t*1000+i*1000).toDouble()],
      rrMs:List.filled(3500,1000),ax:List.filled(3600,0),ay:List.filled(3600,0),az:List.filled(3600,1),
      spo2Red:List.filled(3600,1),spo2Ir:List.filled(3600,1),skinTemp:List.filled(3600,3000),
      skinContact:List.filled(3600,1));
    final staged=restageEditorNapsHeavy(sub,[NapEdit(kind:NapEditKind.added,startSec:t+300,endSec:t+2100,
      snapshot:const {'_stage_only':true})]).single.snapshot!;
    final segments=staged['hypnogram'] as List;
    expect(segments.first['start'],t+300);
    expect(segments.last['end'],t+2100);
    expect(segments.fold<int>(0,(sum,s)=>sum+(s['end'] as int)-(s['start'] as int)),1800);
    expect(staged['start'],t+300);
    expect(staged['end'],t+2100);
  });
  test('receipt composition retains canonical stage output only for the exact requested interval',(){
    final bundle=<String,dynamic>{'naps':{'value':[{'start':1000,'end':2800,
      '_staged_bounds':[1000,2800],'_stage_only':true,'duration_min':21,'deep_min':7}]}};
    const request=NapEdit(kind:NapEditKind.added,startSec:1000,endSec:2800,
      snapshot:{'_stage_only':true,'start':1000,'end':2800,'duration_min':null});
    composeAcceptedNaps(bundle,[request]);
    expect((bundle['naps'] as Map)['value'],[{'start':1000,'end':2800,
      '_staged_bounds':[1000,2800],'_stage_only':true,'duration_min':21,'deep_min':7}]);
    composeAcceptedNaps(bundle,[const NapEdit(kind:NapEditKind.added,startSec:1100,endSec:2800,
      snapshot:{'_stage_only':true,'start':1100,'end':2800,'duration_min':null})]);
    expect(((bundle['naps'] as Map)['value'] as List).single['duration_min'],isNull);
  });
  test('production day worker applies the explicit stage request before composing naps',()async{
    final t=DateTime(2026,11,14).millisecondsSinceEpoch~/1000;
    const duration=3600;
    final sub=Substrate(tsSec:[for(var i=0;i<duration;i++)t+i],hr:List.filled(duration,55),
      rrTsMs:[for(var i=0;i<3500;i++)(t*1000+i*1000).toDouble()],rrMs:List.filled(3500,1000),
      ax:List.filled(duration,0),ay:List.filled(duration,0),az:List.filled(duration,1),
      spo2Red:List.filled(duration,1),spo2Ir:List.filled(duration,1),
      skinTemp:List.filled(duration,3000),skinContact:List.filled(duration,1));
    final input=DerivationEngine.dayBlocksInputForTest(daySub:sub,date:'2026-11-14',dayStartSec:t,
      napEdits:[NapEdit(kind:NapEditKind.added,startSec:t+1800,endSec:t+3300,
        snapshot:const {'_stage_only':true,'duration_min':null})]);
    final dynamic output=await DerivationEngine.runDayBlocksForTest(input);
    final naps=(output.bundlePatch['naps'] as Map)['value'] as List;
    final selected=naps.singleWhere((n)=>n['start']==t+1800);
    expect(selected['end'],t+3300);
    expect(selected['_staged_bounds'],[t+1800,t+3300]);
    expect(selected['hypnogram'],isNotEmpty);
  });

}
