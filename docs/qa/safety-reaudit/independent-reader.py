from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import json,hashlib,zipfile,time
base=Path('/Users/atiliobarreda/Desktop/software/personal/zipper')
d=Path((base/'.build/actual-footage-qualification-path.txt').read_text())
m=json.loads((d/'HANDOFF_MANIFEST.json').read_text());s=Path(m['preflight']['configuration']['sourcePath'])
expected={f['relativePath']:f for f in m['preflight']['files']}
def snapshot(p): return {f.name:(f.stat().st_dev,f.stat().st_ino,f.stat().st_size,f.stat().st_mtime_ns,f.stat().st_ctime_ns) for f in p.iterdir()}
before_source=snapshot(s);before_dest=snapshot(d);start=time.monotonic()
def verify(z):
 rows=[]
 with zipfile.ZipFile(z) as archive:
  for member in archive.infolist():
   assert member.filename in expected
   entry=expected[member.filename]; digest=hashlib.sha256(); count=0
   with archive.open(member) as zipped,(s/member.filename).open('rb') as original:
    while block:=zipped.read(4*1024*1024):
     assert block==original.read(len(block)),member.filename
     digest.update(block);count+=len(block)
    assert original.read(1)==b''
   assert digest.hexdigest()==entry['sha256'];assert count==entry['identity']['size']
   rows.append(member.filename)
 print('INDEPENDENT PASS',z.name,len(rows),'members',flush=True)
 return rows
with ThreadPoolExecutor(max_workers=2) as pool: rows=[n for group in pool.map(verify,sorted(d.glob('*.zip'))) for n in group]
assert len(rows)==len(set(rows))==len(expected)==281;assert set(rows)==set(expected)
assert before_source==snapshot(s);assert before_dest==snapshot(d)
r={'reader':'Python standard-library zipfile','comparison':'Every archived byte compared directly with current original bytes; every member CRC checked by zipfile; every member SHA-256 compared with the manifest','source_bytes':sum(f['identity']['size'] for f in expected.values()),'source_files':len(rows),'archives':8,'passed':True,'source_metadata_unchanged':True,'delivery_metadata_unchanged':True,'elapsed_seconds':round(time.monotonic()-start,3),'destination':str(d)}
(base/'docs/qa/safety-reaudit/actual-footage-independent.json').write_text(json.dumps(r,indent=2)+'\n')
print(json.dumps(r,indent=2),flush=True)
