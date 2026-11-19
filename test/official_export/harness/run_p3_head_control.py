#!/usr/bin/env python3
"""Repeat only a disputed head file under the frozen gate's identical cap."""
import json,os,pathlib,sys
root=pathlib.Path.cwd();driver=root/'test/official_export/harness/run_p3_gate.py'
prefix=driver.read_text().split('before=hashes();head=[];baseline=[];swapped=False')[0]
assert 'def batch(' in prefix and 'for i,line' not in prefix
prefix=prefix.replace("out=root/'build/p3-gate'", "out=root/'build/p3-head-control'")
ns={};exec(compile(prefix,str(driver),'exec'),ns)
files=sys.argv[1:];assert 0<len(files)<=5
before=ns['hashes']()
try:
 ns['config_path'].write_text(json.dumps(ns['config']))
 result=ns['batch'](files,'head-control')
 result['head_commit']=os.environ['P3_CONTROL_HEAD']
 (ns['out']/'result.json').write_text(json.dumps(result,indent=2))
finally:
 ns['config_path'].write_bytes(ns['original'])
 restored=before==ns['hashes']() and ns['config_path'].read_bytes()==ns['original']
 (ns['out']/'restored.json').write_text(json.dumps({'source_and_config_bytes_match':restored},indent=2));assert restored
raise SystemExit(result['exit'])
