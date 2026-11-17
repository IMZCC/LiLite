"""Check the domain inventory against pinned setting keys, routes/screens and concrete code references."""
from pathlib import Path
import json,re
n=Path(__file__).resolve().parents[1];r=n.parent
doc=json.loads((n/'Acceptance/evidence/danmaku-subtitles.json').read_text());audit={v['id']:v for v in doc['rows']}
assert len(audit)==len(doc['rows']),"duplicate IDs"
parity=json.loads((n/'parity.json').read_text())
logged={k for k in parity if re.search('danmaku|subtitle|/(?:enableTapDm|showDmChart)|live_dm_block|liveDmBlockPage',k,re.I)}
assert logged=={k for k in audit if not k.startswith('flow:')},(logged-set(audit),{x for x in audit if not x.startswith('flow:')}-logged)
settings=(r/'lib/utils/storage_key.dart').read_text()
for id,v in audit.items():
 for f in v['upstream']:assert (r/f).is_file(),(id,f)
 for source in v['native']:
  f,sym=source.split('#');assert sym in (n/f).read_text(),(id,source)
 for label in v['proof']:assert (n/doc['proof'][label]).is_file(),(id,label)
 if id.startswith('preference:'):assert re.search(r'\b'+id.split('/')[-1]+r'\b',settings),id
assert doc['device_pending']
print(f"{len(logged)} matching pinned page/route/setting IDs; {len(audit)-len(logged)} behavior flows; all declared source and evidence references resolved")
