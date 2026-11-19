"""Generate search synonyms from pinned Dart, real SwiftUI rows and archive keys.
Run from any directory with the project Swift toolchain. No network or account data is read.
"""
import argparse, json, re, collections, shutil, subprocess, tempfile
from pathlib import Path
here=Path(__file__).resolve().parent
R=here.parents[1]; base=R/"Sources/PiliNative"
arg=argparse.ArgumentParser();arg.add_argument("--write",action="store_true");opt=arg.parse_args()
with tempfile.TemporaryDirectory() as t:
 work=Path(t);swift=Path(shutil.which("swiftc"))
 host=swift.resolve().parent.parent/"lib/swift/host"
 subprocess.run([swift,"-parse-as-library","-I",host,"-L",host,"-Xlinker","-rpath","-Xlinker",host,here/"ControlLabels.swift","-o",work/"labels"],check=True)
 files=sorted(base.rglob("*.swift"))
 A=json.loads(subprocess.check_output([work/"labels",*files]))
 declared=json.loads(subprocess.check_output([work/"labels","--constants",*files]))
 constants=collections.defaultdict(set)
 for value in declared:constants[value['name']].add(value['value'])
 literal_keys={name:next(iter(values)) for name,values in constants.items() if len(values)==1}
 subprocess.run([swift,base/"Network/ServiceError.swift",base/"Settings/BackupFormat.swift",here/"BackupFields.swift","-o",work/"fields"],check=True)
 subprocess.run([work/"fields",work/"fields.json"],check=True)
 fields=json.loads((work/"fields.json").read_text())
aliases=collections.defaultdict(list)
for item in fields:
 aliases[item['path'].split('/')[-1]].append(item['key'])
meta=collections.defaultdict(set)
pin="d9e9626f1a3f89cd9ca85e18f61aaba02634e12a"
for file in subprocess.check_output(["git","-C",R.parent,"ls-tree","-r","--name-only",pin,"lib/pages/setting/models"],text=True).splitlines():
 if not file.endswith(".dart"):continue
 s=subprocess.check_output(["git","-C",R.parent,"show",pin+":"+file]).decode()
 chunks=[]
 end=0
 for mt in re.finditer(r'\b(?:[A-Za-z]\w*Model)(?:<[^;()\n]+>)?(?:\.\w+)?\s*\(',s):
  if mt.start()<end:continue
  beg=mt.end()-1;depth=1;quote=None;i=beg+1
  while i<len(s) and depth:
   c=s[i]
   if quote:
    if c=='\\':i+=2;continue
    if c==quote:quote=None
   elif c in ('"',"'"):quote=c
   elif s[i:i+2]=='//':i=s.find('\n',i);i=len(s) if i<0 else i
   elif s[i:i+2]=='/*':i=s.find('*/',i+2)+1
   elif c=='(':depth+=1
   elif c==')':depth-=1
   i+=1
  end=i;chunks.append(s[beg:end])
 for block in chunks:
  keys=set(re.findall(r'(?:setKey|key):\s*(?:SettingBoxKey|VideoBoxKey)\.(\w+)',block))
  if not keys: keys=set(re.findall(r'\bPref\.(\w+)',block))
  if len(keys)!=1:continue
  strs=re.findall(r"(?m)^\s+(?:(?:get)?[Tt]itle|(?:get)?[Ss]ubtitle|filterScope):\s*(?:\(\)\s*=>\s*)?'([^'\n]{1,150})'",block)
  for st in strs:
   st=re.sub(r'\$\{[^}]*\}|\$\w+',' ',st)
   st=re.sub(r'[\t\n\r"\\]',' ',st).strip(' ：:（）()「」·')
   if st=='当前' or not st:continue
   for key in keys:meta[key].add(st)
sub={'TimingSettings':'PlayerPreferencePanel','PlaybackEntryOptions':'PlayerPreferencePanel','NightSettings':'SettingsView'}
manual={'autosync':('play.autosync','0'),'videoSync':('play.videoSync','system')}
# Native-only settings have no upstream Dart titles; give them search words here.
extra={'SettingsView/自动领取大会员经验':'大会员 经验 领取 每日 签到',
       'PlaybackOptionsView/播放器内核':'mpv AVPlayer libmpv 播放器内核 画中画 隔空播放',
       'SettingsView/播放器内核':'mpv AVPlayer libmpv 播放器内核 画中画 隔空播放',
       'DisplayPanel/强制 120Hz':'高刷 高刷新率 ProMotion 120 帧率 fps 流畅',
       'RecommendationSettings/首个推荐使用大卡片':'大卡片 首卡 推荐卡片 双列 卡片样式'}
anchors=collections.defaultdict(list);known={}
for p in base.rglob('*.swift'):
 txt=p.read_text()
 for anchor in re.findall(r'\.settingAnchor\("([^"\\\n]+)"\)',txt):known[anchor]=p
for r in sorted(A,key=lambda x:x['kind']=='Section'):
 group=sub.get(r['owner'],r['owner']);slug=r.get('anchor') or group+'/'+r['label']
 if slug not in known or slug in anchors:continue
 file=known[slug];s=file.read_text();m=re.search(r'\bstruct '+r['owner']+r'\s*:\s*View\b',s)
 if not m:continue
 s=re.split(r'\n(?:private )?struct ',s[m.end():],maxsplit=1)[0]
 store={}
 for expression,var,default in re.findall(r'@AppStorage\(\s*("[^"]+"|[A-Za-z_]\w*(?:\.\w+)*)\s*\)\s+(?:private\s+)?var (\w+)(?:\s*:\s*[\w?]+)?(?:\s*=\s*([^\n]+))?',s):
  key=expression[1:-1] if expression.startswith('"') else literal_keys.get(expression)
  if key is not None:store[var]=(key,default.strip())
 keys=[];words=[];stored='';default=''
 variables=re.findall(r'\$(\w+)',r['expr'])
 # A direct getter names exactly one stored property; expressions/calls stay unresolved.
 variables+=re.findall(r'\bBinding\s*\(\s*get:\s*\{\s*(?:self\.)?(\w+)\s*\}',r['expr'])
 for var in dict.fromkeys(variables):
  if var in store:
   k,d=store[var];keys+=aliases[k]
   if stored=='' and re.fullmatch(r'(?:true|false|-?\d+(?:\.\d+)?)',d):
    stored=k;default=d
 for node in re.findall(r'\$(?:draft|rules|style)\.(\w+)',r['expr']):keys+=aliases[node]
 if r['kind'] in ('Section','NavigationLink'):keys=[];stored='';default=''
 if r['owner']=='TimingSettings':
  ky='videoSync' if '同步' in r['label'] else 'autosync';keys+=[ky];stored,default=manual[ky]
 for key in keys:
  words.extend([key,*sorted(meta[key])])
 txt=' '.join(dict.fromkeys(words)).replace('\t',' ').replace('"',' ').replace('\\',' ').replace('\n',' ')
 txt=' '.join(filter(None,[txt,extra.get(slug,'')]))
 if txt or stored:anchors[slug]=[txt,stored,default]
p=base/'Settings/SettingSearchTerms.swift'
rows=['\t'.join([key,*vals]) for key,vals in sorted(anchors.items())]
s='''// Upstream titles, subtitles and non-sensitive scalar settings, matched to their native controls.
import Foundation

enum SettingSearchTerms {
  struct Terms { let keywords: String, storage: String, fallback: String }
  private static let rows = """
'''+ '\n'.join(r.rstrip('\t') for r in rows)+'''
"""
  static let byAnchor: [String:Terms] = {
    var result: [String:Terms] = [:]
    for line in rows.split(separator:"\\n") {
      let fields = line.split(separator:"\\t", omittingEmptySubsequences:false).map(String.init)
      guard fields.count >= 2 else { continue }
      result[fields[0]] = .init(keywords:fields[1], storage:fields.count > 2 ? fields[2] : "", fallback:fields.count > 3 ? fields[3] : "")
    }
    return result
  }()
  static func value(for anchor: String, defaults: UserDefaults) -> String {
    guard let v = byAnchor[anchor], !v.storage.isEmpty else { return "" }
    let saved = defaults.object(forKey: v.storage)
    if v.fallback == "true" || v.fallback == "false" {
      return (saved as? Bool ?? (v.fallback == "true")) ? "已开启 已启用 打开" : "已关闭 已停用"
    }
    if v.storage == "play.autosync" || v.storage == "play.videoSync" { return (saved as? String) ?? v.fallback }
    return (saved as? NSNumber)?.stringValue ?? v.fallback
  }
}
'''
if opt.write:p.write_text(s,encoding='utf-8',newline='\n')
elif p.read_text(encoding='utf-8')!=s:raise SystemExit('Stale settings synonyms: rerun with --write')
print(len(rows),'synonym/value rows, extracted',sum(bool(v) for v in meta.values()),'upstream settings')
