#!/usr/bin/env python3
"""Run the frozen import-graph selection serially; retain exact failing cases."""
import json,os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[3]
selection=root/'build/official_probe/graph-files.txt'
files=list(dict.fromkeys(selection.read_text().split()))
files+= [str(p.relative_to(root)) for p in (root/'test/official_export').glob('*_test.dart') if str(p.relative_to(root)) not in files]
out=root/'build/official_probe';out.mkdir(parents=True,exist_ok=True)
os.environ.update(TZ='UTC0',TZDIR='/usr/share/zoneinfo')
results=[];failures=[]
for start in range(0,len(files),40):
 batch=files[start:start+40]
 path=out/f'graph-{start}.jsonl'
 with path.open('w') as log:
  code=subprocess.call(['flutter','test','--no-pub','--concurrency=1','--reporter=json',*batch],cwd=root,stdout=log)
 tests={};counts=dict(passed=0,failed=0,skipped=0)
 for line in path.read_text().splitlines():
  try:e=json.loads(line)
  except ValueError:continue
  if e.get('type')=='testStart':tests[e['test']['id']]=e['test']
  if e.get('type')=='testDone' and not e.get('hidden'):
   key='skipped' if e.get('skipped') else 'passed' if e['result']=='success' else 'failed'
   counts[key]+=1
   if key=='failed':failures.append(tests[e['testID']])
 results.append(dict(batch=start,exit=code,counts=counts));print(results[-1],flush=True)
(out/'graph-summary.json').write_text(json.dumps(dict(results=results,failures=failures),indent=2)+'\n')
print('FAILURES',json.dumps(failures),flush=True)
raise SystemExit(any(r['exit']!=0 for r in results))
