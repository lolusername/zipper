from pathlib import Path
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import xml.etree.ElementTree as ET
import subprocess,json,hashlib
p=Path('/Users/atiliobarreda/Desktop/video/VISUAL DEALERS/VISUAL DEALERS/NYC/CAM 1/XDROOT/Clip')
def snapshot():
 return {f.name:(f.stat().st_dev,f.stat().st_ino,f.stat().st_size,f.stat().st_mtime_ns,f.stat().st_ctime_ns) for f in p.iterdir()}
before=snapshot()
ns={'n':'urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20'}
def inspect(f):
 data=f.read_bytes(); x=ET.fromstring(data); stem=f.name[:-7]
 def attrs(tag): return x.find('n:'+tag,ns).attrib
 expected=attrs('TargetMaterial')['umidRef'].upper()
 proc=subprocess.run(['/opt/homebrew/bin/ffprobe','-v','error','-show_entries','format_tags=material_package_umid','-of','json',str(p/(stem+'.MXF'))],capture_output=True,text=True,timeout=45,check=True)
 got=json.loads(proc.stdout)['format']['tags']['material_package_umid'].removeprefix('0x').upper()
 changes={t.attrib['name']:[e.attrib.get('status') for e in t] for t in x.findall('.//n:ChangeTable',ns)}
 bim=p/(stem+'R01.BIM')
 return {'stem':stem,'xml_sha256':hashlib.sha256(data).hexdigest(),'manufacturer':attrs('Device')['manufacturer'],'model':attrs('Device')['modelName'],'capture_fps':attrs('VideoFormat/n:VideoFrame')['captureFps'],'recording_mode':attrs('RecordingMode')['type'],'bim_present':bim.exists(),'acquisition_events':changes,'xml_mxf_umid_match':expected==got}
with ThreadPoolExecutor(max_workers=4) as e: records=list(e.map(inspect,sorted(p.glob('*.XML'))))
result={'source':str(p),'file_count':len(before),'extensions':dict(Counter(Path(n).suffix for n in before)),'total_source_bytes':sum(v[2] for v in before.values()),'all_xml_mxf_umids_match':all(r['xml_mxf_umid_match'] for r in records),'source_names_sizes_identities_mtimes_ctimes_unchanged':snapshot()==before,'records':records,'limits':'Read-only metadata and header inspection; no full footage hashing, decoding, archive creation, or original-card comparison.'}
Path('docs/qa/safety-reaudit/real-source-metadata.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='records'},indent=2))
print('MODELS',dict(Counter(r['model'] for r in records)))
print('MODES_BIM',dict(Counter((r['recording_mode'],r['capture_fps'],r['bim_present']) for r in records)))
print('NO_BIM',[r for r in records if not r['bim_present']])
