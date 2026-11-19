#!/usr/bin/env python3
"""Run the frozen import-graph selection serially; retain exact failing cases."""
import json,os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[3]
selection=root/'build/official_probe/graph-files.txt'
files=list(dict.fromkeys(selection.read_text().split()))
for directory in ['test/official_export','test/guards']:
 files+= [str(p.relative_to(root)) for p in (root/directory).rglob('*_test.dart') if str(p.relative_to(root)) not in files]
out=root/'build/official_probe';out.mkdir(parents=True,exist_ok=True)
os.environ.update(TZ='UTC0',TZDIR='/usr/share/zoneinfo')
results=[];failures=[];incomplete=[]
resume_before=int(os.environ.get('P2_GRAPH_RESUME_BEFORE','0'))
for start in range(0,len(files),40):
 batch=files[start:start+40]
 path=out/f'graph-{start}.jsonl'
 if start < resume_before:
  # Reuse only an explicitly requested, fully terminated batch. Source hashes
  # are checked by the caller before resuming; partial batches always rerun.
  prior=[json.loads(line) for line in path.read_text().splitlines() if line.startswith('{')]
  assert any(e.get('type')=='done' for e in prior),('cannot resume incomplete batch',start)
  code=0 if next(e for e in reversed(prior) if e.get('type')=='done')['success'] else 1
 else:
  with path.open('w') as log:
   code=subprocess.call(['flutter','test','--no-pub','--concurrency=1','--reporter=json',*batch],cwd=root,stdout=log)
 tests={};suites={};errors={};finished=set();done=False;counts=dict(passed=0,failed=0,skipped=0)
 for line in path.read_text().splitlines():
  try:e=json.loads(line)
  except ValueError:continue
  if e.get('type')=='suite':suites[e['suite']['id']]=e['suite']['path']
  if e.get('type')=='testStart':tests[e['test']['id']]=e['test']
  if e.get('type')=='error':errors.setdefault(e.get('testID'),[]).append(e['error'])
  if e.get('type')=='done':done=True
  if e.get('type')=='testDone':finished.add(e['testID'])
  if e.get('type')=='testDone' and not e.get('hidden'):
   key='skipped' if e.get('skipped') else 'passed' if e['result']=='success' else 'failed'
   counts[key]+=1
   if key=='failed':
    test=tests[e['testID']]
    failures.append(dict(test,file=suites.get(test['suiteID']),errors=errors.get(e['testID'],[])))
 missing=set(batch)-{str(pathlib.Path(p).relative_to(root)) for p in suites.values()}
 complete=done and not (tests.keys()-finished) and not missing and not (code!=0 and counts['failed']==0)
 if not complete:incomplete.append(dict(batch=start,done=done,pending=sorted(tests.keys()-finished),missing=sorted(missing)))
 results.append(dict(batch=start,exit=code,counts=counts,complete=complete,timeout_policy='stock test_api' if start < resume_before else os.environ.get('P2_GRAPH_TIMEOUT_POLICY','stock test_api')));print(results[-1],flush=True)
(out/'graph-summary.json').write_text(json.dumps(dict(results=results,failures=failures,incomplete=incomplete),indent=2)+'\n')
print('FAILURES',json.dumps(failures),flush=True)
raise SystemExit(bool(incomplete) or any(r['exit']!=0 for r in results))
