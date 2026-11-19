#!/usr/bin/env python3
"""Compare the existing translation guard at head and P2; restore ARBs exactly."""
import hashlib,json,pathlib,subprocess,tarfile
root=pathlib.Path.cwd();out=root/'build/p3-l10n';out.mkdir(parents=True,exist_ok=True)
paths=list((root/'lib/l10n').glob('app_*.arb'))
original={p:p.read_bytes() for p in paths};results=[]
def run(label):
 p=subprocess.run(['flutter','test','--no-pub','-j','1','-r','expanded','test/l10n_no_english_copies_test.dart'],capture_output=True,text=True)
 log=p.stdout+p.stderr;(out/(label+'.log')).write_text(log)
 return {'label':label,'exit':p.returncode,'assertion_failed':'Expected: empty' in log,'compiler_error':'Failed to load' in log}
try:
 results.append(run('head'))
 with tarfile.open(root/'build/p3-base.tar') as archive:
  base={p:archive.extractfile(str(p.relative_to(root))).read() for p in paths}
 # Independently compare every accidental-copy candidate, including entries
 # beyond matcher truncation. Existing allowlist is unchanged at head.
 def copies(data):
  arbs={p.stem[4:]:json.loads(v) for p,v in data.items()};en=arbs['en']
  return {(code,k,v) for code,arb in arbs.items() if code!='en' for k,v in en.items()
    if not k.startswith('@') and isinstance(v,str) and len(v)>12 and ' ' in v and arb.get(k)==v}
 new=sorted(copies(original)-copies(base))
 for p,data in base.items():p.write_bytes(data)
 results.append(run('base'))
finally:
 for p,data in original.items():p.write_bytes(data)
 restored=all(p.read_bytes()==data for p,data in original.items())
summary={'results':results,'new_copy_candidates':new,'source_bytes_restored':restored,
 'arb_sha256':{str(p.relative_to(root)):hashlib.sha256(data).hexdigest() for p,data in original.items()}}
(out/'summary.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary))
assert restored and not new
assert all(r['exit']==1 and r['assertion_failed'] and not r['compiler_error'] for r in results)
