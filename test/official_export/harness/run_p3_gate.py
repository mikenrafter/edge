#!/usr/bin/env python3
"""Run the frozen select_tests batches once; resolve failures against P2 base.

Both head and any required base replay use a private 120s test_api cap. Stock
configuration and all source bytes are restored in finally. No owner data.
"""
import hashlib,json,os,pathlib,shutil,subprocess,tarfile,time,urllib.parse
root=pathlib.Path.cwd()
out=root/'build/p3-gate';out.mkdir(parents=True,exist_ok=True)
selection=root/'build/p3-selection.txt'
base_archive=root/'build/p3-base.tar'
config_path=root/'.dart_tool/package_config.json';original=config_path.read_bytes()
config=json.loads(original);package=next(p for p in config['packages'] if p['name']=='test_api')
source=pathlib.Path(urllib.parse.unquote(urllib.parse.urlparse(urllib.parse.urljoin(config_path.as_uri(),package['rootUri'])).path))
relative='lib/src/backend/invoker.dart';text=(source/relative).read_text()
needle='var timeout = liveTest.test.metadata.timeout.apply(defaultTimeout);';assert text.count(needle)==1
replacement='final requested = liveTest.test.metadata.timeout.apply(defaultTimeout);\n    const cap = Duration(seconds:120);\n    final Duration timeout = requested == null || requested > cap ? cap : requested;'
overlay=out/'test-api';shutil.rmtree(overlay,ignore_errors=True);shutil.copytree(source,overlay)
(overlay/relative).write_text(text.replace(needle,replacement).replace('    if (timeout == null) return;\n',''))
package['rootUri']=overlay.as_uri()+'/'
(out/'policy.json').write_text(json.dumps(dict(cap_seconds=120,stock_sha256=hashlib.sha256(text.encode()).hexdigest(),overlay_sha256=hashlib.sha256((overlay/relative).read_bytes()).hexdigest()),indent=2))
def hashes():
 return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for top in ['lib','test'] for p in (root/top).rglob('*') if p.is_file()}
def batch(files,label):
 log=out/(label+'.jsonl');start=time.monotonic()
 with log.open('w') as stream:
  code=subprocess.call(['flutter','test','--no-pub','--concurrency=1','--reporter=json',*files],stdout=stream,stderr=subprocess.STDOUT)
 tests={};suites={};counts=dict(passed=0,failed=0,skipped=0);failures=[];done=False
 for line in log.read_text().splitlines():
  try:event=json.loads(line)
  except ValueError:continue
  if event.get('type')=='suite':suites[event['suite']['id']]=event['suite'].get('path','')
  if event.get('type')=='testStart':tests[event['test']['id']]=event['test']
  if event.get('type')=='testDone':
   t=tests.get(event['testID'],{});name=t.get('name','')
   if name.startswith('loading ') and event.get('result')=='success':continue
   key='skipped' if event.get('skipped') else 'passed' if event.get('result')=='success' else 'failed'
   counts[key]+=1
   if key=='failed':failures.append(dict(file=(t.get('url') or suites.get(t.get('suiteID'),'')).split('/test/',1)[-1],name=name))
  if event.get('type')=='done':done=True
 result=dict(label=label,files=files,exit=code,counts=counts,failures=failures,incomplete=not done,seconds=round(time.monotonic()-start,2))
 print(json.dumps(result),flush=True);return result
before=hashes();head=[];baseline=[];swapped=False
backup=out/'head-source.tar'
try:
 config_path.write_text(json.dumps(config))
 for i,line in enumerate(selection.read_text().splitlines()):
  files=line.split();assert 0<len(files)<=5
  head.append(batch(files,f'head-{i:03}'))
  (out/'head.json').write_text(json.dumps(head,indent=2))
 failures={f['file'] for r in head for f in r['failures']}
 if failures:
  with tarfile.open(backup,'w') as archive:
   for top in ['lib','test']:archive.add(root/top,arcname=top)
  for top in ['lib','test']:shutil.rmtree(root/top)
  swapped=True
  with tarfile.open(base_archive) as archive:archive.extractall(root)
  # Generated locale code is absent in the Git archive, and must match base.
  subprocess.run(['flutter','gen-l10n'],check=True,stdout=subprocess.DEVNULL)
  old=[str(pathlib.Path('test')/f) for f in sorted(failures) if (root/'test'/f).is_file()]
  for i in range(0,len(old),5):baseline.append(batch(old[i:i+5],f'base-{i//5:03}'))
 head_errors={(f['file'],f['name']) for r in head for f in r['failures']}
 base_errors={(f['file'],f['name']) for r in baseline for f in r['failures']}
 summary=dict(base='00dcf6a6e',head_counts={k:sum(r['counts'][k] for r in head) for k in ['passed','failed','skipped']},
  batches=len(head),baseline_counts={k:sum(r['counts'][k] for r in baseline) for k in ['passed','failed','skipped']},
  infrastructure_failures=[r['label'] for r in head+baseline if r['exit'] and not r['failures']],new_failures=sorted(head_errors-base_errors),baseline_only=sorted(base_errors-head_errors),incomplete=[r['label'] for r in head+baseline if r['incomplete']])
 (out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary),flush=True)
finally:
 if swapped:
  for top in ['lib','test']:shutil.rmtree(root/top)
  with tarfile.open(backup) as archive:archive.extractall(root)
 config_path.write_bytes(original)
 after=hashes();restored=before==after
 (out/'restored.json').write_text(json.dumps(dict(source_bytes_match=restored,config_bytes_match=config_path.read_bytes()==original),indent=2))
 assert restored,'source restoration mismatch'
raise SystemExit(bool(summary['new_failures'] or summary['incomplete'] or summary['infrastructure_failures']))
