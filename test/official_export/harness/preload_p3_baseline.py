#!/usr/bin/env python3
"""Replay a known widget failure on P2 while the one head gate continues elsewhere."""
import json,pathlib,shutil,subprocess,sys,tarfile
root=pathlib.Path.cwd();driver=root/'test/official_export/harness/run_p3_gate.py'
ns={};prefix=driver.read_text().split('before=hashes();head=[];baseline=[];swapped=False')[0]
assert 'def batch(' in prefix and 'for i,line' not in prefix
exec(compile(prefix,str(driver),'exec'),ns)
files=sys.argv[1:];assert 0<len(files)<=5
out=root/'build/p3-gate/preloaded';out.mkdir(exist_ok=True)
before=ns['hashes']();backup=out/'source.tar';swapped=False
try:
 with tarfile.open(backup,'w') as archive:
  for top in ['lib','test']:archive.add(root/top,arcname=top)
 for top in ['lib','test']:shutil.rmtree(root/top)
 swapped=True
 with tarfile.open(root/'build/p3-base.tar') as archive:archive.extractall(root)
 subprocess.run(['flutter','gen-l10n'],check=True,stdout=subprocess.DEVNULL)
 ns['config_path'].write_text(json.dumps(ns['config']))
 result=ns['batch'](files,'base-preloaded')
 shutil.copy2(ns['out']/'base-preloaded.jsonl',out/'base-preloaded.jsonl')
 (out/'result.json').write_text(json.dumps(result,indent=2))
finally:
 if swapped:
  for top in ['lib','test']:shutil.rmtree(root/top)
  with tarfile.open(backup) as archive:archive.extractall(root)
 ns['config_path'].write_bytes(ns['original'])
 restored=before==ns['hashes']() and ns['config_path'].read_bytes()==ns['original']
 (out/'restored.json').write_text(json.dumps({'source_and_config_bytes_match':restored},indent=2));assert restored
assert not result['incomplete']
