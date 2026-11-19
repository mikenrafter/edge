#!/usr/bin/env python3
"""Four assertion-killed P3 mutations. Restore exact bytes in finally."""
import hashlib,json,pathlib,subprocess,time
root=pathlib.Path.cwd();out=root/'build/p3-mutations';out.mkdir(parents=True,exist_ok=True)
coordinator=root/'lib/data/official_export/coordinator.dart';space=root/'lib/data/official_export/space_budget.dart'
original={p:p.read_bytes() for p in [coordinator,space]};results=[]
def skip_verification(text):
 start=text.index('  Future<void> _verify(');body=text.index(' async {',start)+len(' async {')
 end=text.index('\n  Future<OfficialExportOutcome> _run(',body)
 return text[:body]+'\n  }\n'+text[end:]
def skip_final(text):
 needle='    await _verify(_incomplete!,expected,size,artifact);'
 assert text.count(needle)==2
 first=text.index(needle);second=text.index(needle,first+1)
 return text[:second]+text[second:].replace(needle,'    // mutation: trust rename',1)
cases=[('floor',space,lambda t:t.replace('if (free - nextWriteBytes < liveFloorBytes)','if (false)',1),'preflight refuses before capture'),
 ('saved-byte-authentication',coordinator,skip_verification,'corrupt keeps receipts'),
 ('rename-boundary',coordinator,skip_final,'rename keeps receipts'),
 ('plaintext-before-recovery',coordinator,lambda t:t.replace('    await plain.delete();','    // mutation: leave plaintext',1),'saved keeps receipts')]
try:
 for label,path,mutate,name in cases:
  before=path.read_text();after=mutate(before);assert after!=before
  path.write_text(after)
  try:
   start=time.monotonic();run=subprocess.run(['flutter','test','--no-pub','--concurrency=1','-r','expanded','--plain-name',name,'test/official_export/coordinator_test.dart'],capture_output=True,text=True)
   log=run.stdout+run.stderr;(out/(label+'.log')).write_text(log)
   killed=run.returncode!=0 and 'Expected:' in log and 'Failed to load' not in log
   result=dict(mutation=label,test=name,exit=run.returncode,assertion_killed=killed,seconds=round(time.monotonic()-start,2));results.append(result);print(json.dumps(result),flush=True)
  finally:path.write_bytes(original[path])
finally:
 for path,data in original.items():path.write_bytes(data)
 restored=all(path.read_bytes()==data for path,data in original.items())
 summary=dict(results=results,source_bytes_restored=restored)
 (out/'summary.json').write_text(json.dumps(summary,indent=2));assert restored
raise SystemExit(not(len(results)==4 and all(r['assertion_killed'] for r in results)))
