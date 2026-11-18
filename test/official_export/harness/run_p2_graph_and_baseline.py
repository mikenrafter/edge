#!/usr/bin/env python3
"""Bound the selected graph suite's known widget hangs; restore stock config.

Only this broad graph/baseline pair uses the isolated test_api copy. Focused
mutations, restored controls, and all tagged receiver runs remain stock.
"""
import hashlib, json, os, pathlib, shutil, subprocess, urllib.parse

root=pathlib.Path(__file__).resolve().parents[3]
config_path=root/'.dart_tool/package_config.json'
original=config_path.read_bytes()
config=json.loads(original)
package=next(p for p in config['packages'] if p['name']=='test_api')
uri=urllib.parse.urlparse(urllib.parse.urljoin(config_path.as_uri(),package['rootUri']))
assert uri.scheme=='file',uri
source=pathlib.Path(urllib.parse.unquote(uri.path))
relative='lib/src/backend/invoker.dart'
text=(source/relative).read_text()
needle='var timeout = liveTest.test.metadata.timeout.apply(defaultTimeout);'
assert text.count(needle)==1,'unsupported test_api timeout implementation'
replacement='final requested = liveTest.test.metadata.timeout.apply(defaultTimeout);\n    const cap = Duration(seconds: 120);\n    final Duration timeout = requested == null || requested > cap ? cap : requested;'
overlay=root/'build/official_probe/graph-test-api'
shutil.rmtree(overlay,ignore_errors=True)
shutil.copytree(source,overlay)
(overlay/relative).write_text(text.replace(needle,replacement).replace('    if (timeout == null) return;\n',''))
package['rootUri']=overlay.as_uri()+'/'
policy='120-second cap (isolated test_api overlay); resumed completed batches stock'
identity=dict(policy=policy,stock_root=str(source),overlay=str(overlay),
 stock_invoker_sha256=hashlib.sha256(text.encode()).hexdigest(),
 overlay_invoker_sha256=hashlib.sha256((overlay/relative).read_bytes()).hexdigest())
(root/'build/official_probe/graph-timeout-policy.json').write_text(json.dumps(identity,indent=2)+'\n')
print('GRAPH TIMEOUT POLICY:',policy,flush=True)
try:
 config_path.write_text(json.dumps(config,indent=2))
 env=dict(os.environ,P2_GRAPH_TIMEOUT_POLICY='120-second cap (isolated test_api overlay)')
 graph=subprocess.call(['python3','-I','test/official_export/harness/run_p2_gate.py'],cwd=root,env=env)
 baseline=subprocess.call(['python3','-I','test/official_export/harness/run_p2_baseline.py'],cwd=root,env=env)
 print('Selected graph exit',graph,'; baseline exit',baseline,flush=True)
finally:
 config_path.write_bytes(original)
 print('RESTORED stock package configuration',flush=True)
raise SystemExit(baseline)
