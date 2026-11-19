#!/usr/bin/env python3
"""Resolve only capped parity fixtures by executing their declared time budgets.

This does not alter the original graph or baseline comparison. Any other
unmatched failure, incomplete comparison, or failed rerun still stops the gate.
"""
import hashlib,json,os,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[3]
out=root/'build/official_probe'
comparison=json.loads((out/'baseline-comparison.json').read_text())
reference=json.loads((out/'baseline-reference.json').read_text())
assert comparison['complete'] and comparison['base']==reference['ref']
assert comparison['archive_sha256']==reference['archive_sha256']
assert not comparison['base_only'],comparison['base_only']
file='test/derive_unchanged_skip_test.dart'
expected={'skipping unchanged days stores exactly what deriving them does',
 'an override, new data, a profile change and a version bump re-derive'}
unmatched=comparison['unmatched_current']
assert unmatched and all(f==file and n in expected for f,n in unmatched),unmatched
failures=json.loads((out/'graph-summary.json').read_text())['failures']
for f,n in unmatched:
 row=next(x for x in failures if str(pathlib.Path(x['file']).relative_to(root))==f and x['name']==n)
 assert row['errors'][0].startswith('TimeoutException after 0:02:00.'),row
# The original source, including generated localizations, must be restored.
lib_hashes=json.loads((out/'lib-before-baseline-sha256.json').read_text())
def check_source():
 actual={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
  for p in (root/'lib').rglob('*') if p.is_file()}
 assert actual==lib_hashes,'source differs from the tested graph/baseline'
check_source()
config=json.loads((root/'.dart_tool/package_config.json').read_text())
api=next(p['rootUri'] for p in config['packages'] if p['name']=='test_api')
assert 'graph-test-api' not in api,api
log_path=out/'derive-unchanged-stock.jsonl'
with log_path.open('w') as log:
 code=subprocess.call(['flutter','test','--no-pub','--concurrency=1','--reporter=json',file],cwd=root,stdout=log)
tests={};finished={};done=False
for line in log_path.read_text().splitlines():
 try:e=json.loads(line)
 except ValueError:continue
 if e.get('type')=='testStart':tests[e['test']['id']]=(e['test']['name'],e['time'])
 if e.get('type')=='testDone':finished[e['testID']]=e
 if e.get('type')=='done':done=True
results=[dict(name=n,result=finished[k]['result'],elapsed_ms=finished[k]['time']-start)
 for k,(n,start) in tests.items() if n in expected and k in finished]
passed=code==0 and done and len(results)==2 and all(x['result']=='success' for x in results)
check_source()
result=dict(fork_head=os.environ.get('OFFICIAL_FORK_HEAD'),base=reference['ref'],
 original_exact_matches=len(comparison['matched']),resolved_unmatched=unmatched,
 test_api=api,declared_budgets_minutes=[10,15],exit=code,complete=done,
 passed=passed,tests=results,lib_hashes_matched=len(lib_hashes))
(out/'baseline-resolution.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
raise SystemExit(not passed)
