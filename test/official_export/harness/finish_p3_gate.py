#!/usr/bin/env python3
"""Attribute the one frozen gate by suite path; replay only missing base files.

Flutter widget tests can put package:flutter_test/... in test.url. The suite
path owns file attribution. Keep all raw evidence and compare diagnostics too.
"""
import hashlib,json,pathlib,re,shutil,subprocess,tarfile,time
root=pathlib.Path.cwd();out=root/'build/p3-gate';extra=out/'attributed';extra.mkdir(exist_ok=True)
def parse(path):
 tests={};suites={};errors={};prints={};failed=[];done=False
 for line in path.read_text().splitlines():
  try:e=json.loads(line)
  except ValueError:continue
  kind=e.get('type');tid=e.get('testID')
  if kind=='suite':suites[e['suite']['id']]=e['suite'].get('path','')
  if kind=='testStart':tests[e['test']['id']]=e['test']
  if kind=='error':errors.setdefault(tid,[]).append(e.get('error',''))
  if kind=='print' and any(x in e.get('message','') for x in ['Expected:','EXCEPTION CAUGHT','overflowed']):prints.setdefault(tid,[]).append(e['message'])
  if kind=='testDone' and e.get('result')!='success' and not e.get('skipped'):failed.append(tid)
  if kind=='done':done=True
 rows=[]
 for tid in failed:
  t=tests.get(tid,{});file=(suites.get(t.get('suiteID')) or t.get('url') or '').split('/test/',1)[-1]
  diagnostic='\n'.join(errors.get(tid,[])+prints.get(tid,[]))
  diagnostic=re.sub(r'file://'+re.escape(str(root))+'/', '',diagnostic).replace(str(root)+'/','')
  diagnostic=re.sub(r'/tmp/[^\s/]+', '/tmp/TEMP',diagnostic)
  diagnostic=re.sub(r'\\x1b\[[0-9;]*m','',diagnostic)
  rows.append(dict(file=file,name=t.get('name',''),diagnostic=diagnostic))
 return rows,done
head=[row for p in sorted(out.glob('head-*.jsonl')) for row in parse(p)[0]]
base_logs=list(sorted(out.glob('base-*.jsonl')))
covered={}
for p in base_logs:
 for line in p.read_text().splitlines():
  try:e=json.loads(line)
  except ValueError:continue
  if e.get('type')=='suite':covered[e['suite'].get('path','').split('/test/',1)[-1]]=True
missing=sorted({r['file'] for r in head if r['file'] not in covered and (root/'test'/r['file']).is_file()})
config_path=root/'.dart_tool/package_config.json';config_bytes=config_path.read_bytes();config=json.loads(config_bytes)
package=next(p for p in config['packages'] if p['name']=='test_api');package['rootUri']=(out/'test-api').as_uri()+'/'
def hashes():return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for top in ['lib','test'] for p in (root/top).rglob('*') if p.is_file()}
before=hashes();swapped=False;backup=extra/'source.tar'
try:
 if missing:
  with tarfile.open(backup,'w') as archive:
   for top in ['lib','test']:archive.add(root/top,arcname=top)
  for top in ['lib','test']:shutil.rmtree(root/top)
  swapped=True
  with tarfile.open(root/'build/p3-base.tar') as archive:archive.extractall(root)
  subprocess.run(['flutter','gen-l10n'],check=True,stdout=subprocess.DEVNULL)
  config_path.write_text(json.dumps(config))
  for i in range(0,len(missing),5):
   files=['test/'+f for f in missing[i:i+5]];log=extra/f'base-missing-{i//5:03}.jsonl';start=time.monotonic()
   with log.open('w') as stream:code=subprocess.call(['flutter','test','--no-pub','-j','1','-r','json',*files],stdout=stream,stderr=subprocess.STDOUT)
   rows,done=parse(log);print(json.dumps(dict(files=files,exit=code,failures=rows,complete=done,seconds=round(time.monotonic()-start,2))),flush=True)
   assert done,'incomplete baseline replay'
   base_logs.append(log)
finally:
 if swapped:
  for top in ['lib','test']:shutil.rmtree(root/top)
  with tarfile.open(backup) as archive:archive.extractall(root)
 config_path.write_bytes(config_bytes)
 restored=before==hashes() and config_path.read_bytes()==config_bytes
 (extra/'restored.json').write_text(json.dumps({'source_and_config_bytes_match':restored},indent=2));assert restored
base=[row for p in base_logs for row in parse(p)[0]]
key=lambda r:(r['file'],r['name'])
h={key(r):r for r in head};b={key(r):r for r in base}
summary={'head_failure_count':len(head),'base_failure_count':len(base),'missing_base_files_replayed':missing,
 'new_failure_identities':sorted(h.keys()-b.keys()),'baseline_only':sorted(b.keys()-h.keys()),
 'matching_diagnostics':sorted(k for k in h.keys()&b.keys() if h[k]['diagnostic']==b[k]['diagnostic']),
 'different_diagnostics':sorted(k for k in h.keys()&b.keys() if h[k]['diagnostic']!=b[k]['diagnostic'])}
(extra/'failures.json').write_text(json.dumps({'head':head,'base':base},indent=2))
(extra/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary),flush=True)
