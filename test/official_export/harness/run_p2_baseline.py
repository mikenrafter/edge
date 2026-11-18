#!/usr/bin/env python3
"""Reproduce selected-gate failures against the frozen base lib, restoring finally.

build/official_probe/base-lib.tar must be `git archive origin/integrate/next lib`.
This runs only after the selected gate, on the idle owned Boat worktree.
"""
import json, os, pathlib, subprocess, tarfile

root=pathlib.Path(__file__).resolve().parents[3]
out=root/'build/official_probe'
gate=json.loads((out/'graph-summary.json').read_text())
assert not gate['incomplete'],gate['incomplete']
current=gate['failures']
files=sorted({str(pathlib.Path(f['file']).relative_to(root)) for f in current})
os.environ.update(TZ='UTC0',TZDIR='/usr/share/zoneinfo')
saved={p:p.read_bytes() for p in (root/'lib').rglob('*') if p.is_file()}
members=[]
try:
 if files:
  with tarfile.open(out/'base-lib.tar') as archive:
   members=[root/m.name for m in archive.getmembers() if m.isfile()]
   assert all(p.is_relative_to(root/'lib') for p in members)
   archive.extractall(root,filter='data')
  # Generated localization Dart files are gitignored. The base ARBs must
  # generate their own API before compiling base widgets. All lib bytes,
  # including generated files, are restored below.
  subprocess.run(['flutter','gen-l10n'],cwd=root,check=True)
  with (out/'baseline.jsonl').open('w') as log:
   subprocess.run(['flutter','test','--no-pub','--concurrency=1','--reporter=json',*files],cwd=root,stdout=log)
finally:
 for path,data in saved.items():path.write_bytes(data)
 for path in (root/'lib').rglob('*'):
  if path.is_file() and path not in saved:path.unlink()

def signature(errors):
 text='\n'.join(errors)
 return [line.strip() for line in text.splitlines() if line.strip().startswith(('Expected:','Actual:','Which:'))] or [text]

def key(test):return str(pathlib.Path(test['file']).relative_to(root)),test['name']
baseline={};suites={};tests={};errors={}
if files:
 for line in (out/'baseline.jsonl').read_text().splitlines():
  try:event=json.loads(line)
  except ValueError:continue
  if event.get('type')=='suite':suites[event['suite']['id']]=event['suite']['path']
  if event.get('type')=='testStart':tests[event['test']['id']]=event['test']
  if event.get('type')=='error':errors.setdefault(event.get('testID'),[]).append(event['error'])
  if event.get('type')=='testDone' and event['result']!='success' and not event.get('skipped'):
   test=tests[event['testID']]
   row=dict(test,file=suites[test['suiteID']],errors=errors.get(event['testID'],[]))
   baseline[key(row)]=signature(row['errors'])
actual={key(t):signature(t['errors']) for t in current}
comparison={'base':'origin/integrate/next','files':files,'matched':[
 {'file':k[0],'test':k[1],'signature':v} for k,v in actual.items() if baseline.get(k)==v],
 'unmatched_current':[k for k,v in actual.items() if baseline.get(k)!=v],
 'base_only':[k for k in baseline if k not in actual]}
(out/'baseline-comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
print(json.dumps(comparison),flush=True)
raise SystemExit(bool(comparison['unmatched_current'] or comparison['base_only']))
