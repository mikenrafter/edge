#!/usr/bin/env python3
"""Each mutation must cause a matcher assertion, and each source is restored."""
import json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[3]
L='lib/data/official_export/';T='test/official_export/'
mutations={
 'fork result after verification':(L+'mapper.dart','    verified = true;', '''    await targetFile.writeRow('day_result',{'day_id':'2026-10-20','algo_version':124,'payload_json':'{"fork":true}','computed_at':1});
    verified = true;''',T+'mapper_test.dart'),
 'fork checkpoint after verification':(L+'mapper.dart','    verified = true;', '''    await targetFile.writeRow('day_checkpoint',{'day_id':'2026-10-20','algo_version':125,'fmt':5,'ctx_sig':'fork','cp_rec_ts':1,'rev_vec':Uint8List(1),'state':Uint8List(1),'computed_at':1});
    verified = true;''',T+'mapper_test.dart'),
 'cursor dropped from finished file':(L+'mapper.dart','    verified = true;',"    await targetFile.applySql('DELETE FROM sync_cursor');\n    verified = true;",T+'mapper_test.dart'),
 'archive policy discarded':(L+'mapper.dart','    verified = true;',"    await targetFile.applySql('DELETE FROM compute_freshness');\n    verified = true;",T+'mapper_test.dart'),
 'obsolete fork live cursor':(L+'prune_cursor.dart','  final edge = calendar.midnightAtOrAfter(oldestExactSec);','  final edge = forkCursorSec;',T+'archive_mapping_test.dart'),
 'stale beats after live empty':(L+'mapper.dart','    verified = true;',"    await targetFile.writeRow('decoded_rr',{'device_id':'','ts_ms':1792756800000,'rec_ts':1792756800,'beat_index':0,'rr_ts_ms':1792756800000,'rr_ms':800.0});\n    verified = true;",T+'archive_mapping_test.dart'),
 'archive row dropped':(L+'mapping_worker.dart',"final sourceRows = table == 'decoded_onehz' ? [content['parent']] : content['beats'] as List;","final sourceRows = table == 'decoded_onehz' ? [] : content['beats'] as List;",T+'archive_mapping_test.dart'),
 'wrong source identity in ledger':(L+'mapper.dart','group.add([id, id]);','group.add([id + 1, id + 1]);',T+'mapper_test.dart'),
 'unit key qualification removed':(L+'mapping_worker.dart',"  return 'custom_u1_${hex(key)}_${hex(unit)}';","  return key;",T+'mapper_test.dart'),
 'live space floor removed':(L+'space_budget.dart','if (free - nextWriteBytes < liveFloorBytes)', 'if (false)',T+'space_budget_test.dart'),
}
results=[];out=root/'build/official_probe/p2-mutations';out.mkdir(parents=True,exist_ok=True)
for name,(path,old,new,test) in mutations.items():
 file=root/path;original=file.read_text()
 try:
  assert old in original,(name,'missing mutation anchor')
  mutated=original.replace(old,new,1)
  file.write_text(mutated)
  run=subprocess.run(['flutter','test','--concurrency=1','-r','expanded',test],cwd=root,text=True,capture_output=True)
  text=run.stdout+run.stderr
  killed=run.returncode!=0 and 'Expected:' in text and 'Actual:' in text and 'Compilation failed' not in text
  row=dict(name=name,exit=run.returncode,assertion_killed=killed);results.append(row)
  (out/(name.replace(' ','-')+'.log')).write_text(text)
  print(row,flush=True)
 finally:file.write_text(original)
(out/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
raise SystemExit(not all(r['assertion_killed'] for r in results))
