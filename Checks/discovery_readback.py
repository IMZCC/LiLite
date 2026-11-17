"""Compile the app's discovery contracts; add --live for public, anonymous GET readbacks."""
import argparse
import hashlib
import re
import time
import json
import subprocess
import tempfile
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

src = Path(__file__).resolve().parents[1] / "Sources/PiliNative"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--live", action="store_true")
args = parser.parse_args()

def signed_searches():
    # Match the public parameters and signature used by Network/WebQuery.swift.
    _, nav = guest(("nav", ("/x/web-interface/nav", {})))
    images = nav["wbi_img"]
    key = "".join(images[k].rsplit("/",1)[-1].split(".")[0] for k in ("img_url","sub_url"))
    table = re.search(r"let offsets = \[(.+?)\]", (src/"Network/WebQuery.swift").read_text(), re.S).group(1)
    mix = "".join(key[int(i)] for i in re.findall(r"\d+",table))
    choices = {"all": {}, "video":{"order":"click","duration":"1","tids":"3"},
               "bili_user":{"order":"fans","order_sort":"0","user_type":"1"},
               "article":{"order":"pubdate","category_id":"1"},"media_bangumi":{},"media_ft":{},"live_room":{}}
    for kind, opts in choices.items():
        q = {"keyword":"世界" if kind.startswith("media_") else "音乐","page":"1","page_size":"20","platform":"pc","web_location":"1430654",**opts}
        path = "/x/web-interface/wbi/search/all/v2" if kind=="all" else "/x/web-interface/wbi/search/type"
        if kind!="all": q["search_type"]=kind
        q["wts"]=str(int(time.time()))
        canonical=urllib.parse.urlencode(sorted(q.items()),quote_via=urllib.parse.quote)
        q["w_rid"]=hashlib.md5((canonical+mix).encode()).hexdigest()
        _, value=guest((kind,(path,q)))
        if value.get("v_voucher"): raise RuntimeError(f"{kind}: search requires verification")
        yield "search-"+kind, value

def guest(key_route):
    key, (route, query) = key_route
    url = "https://api.bilibili.com"+route+"?"+urllib.parse.urlencode(query)
    req = urllib.request.Request(url, headers={"User-Agent":"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1","Referer":"https://www.bilibili.com/"})
    with urllib.request.urlopen(req, timeout=15) as inp:
        packet = json.load(inp)
    if packet["code"] != 0 and not (key=="nav" and packet["code"]==-101):
        raise RuntimeError(f"{key}: service code {packet['code']}")
    return key, packet.get("data") if packet.get("data") is not None else packet.get("result")

routes = {
    "anime": ("/pgc/season/index/condition", {"season_type":1,"type":0}),
    "cinema": ("/pgc/season/index/condition", {"index_type":102,"type":0}),
    "result1": ("/pgc/season/index/result", {"season_type":1,"type":0,"page":1,"pagesize":21}),
    "result2": ("/pgc/season/index/result", {"season_type":1,"type":0,"page":2,"pagesize":21}),
    "rank1": ("/pgc/web/rank/list", {"season_type":1,"day":3}),
    "rank2": ("/pgc/season/rank/web/list", {"season_type":2,"day":3}),
    "hot": ("/x/v2/search/trending/ranking", {"limit":30}),
    "weeks": ("/x/web-interface/popular/series/list", {}),
    "timeline1": ("/pgc/web/timeline", {"types":1,"before":6,"after":6}),
    "timeline4": ("/pgc/web/timeline", {"types":4,"before":6,"after":6}),
}
with tempfile.TemporaryDirectory() as tmp:
    d = Path(tmp)
    creator = (src/"Social/Creators.swift").read_text()
    (d/"Creator.swift").write_text("import Foundation\nstruct Creator:" + creator.split("struct Creator:",1)[1].split("struct FollowGroup:",1)[0])
    files = [src/(s+".swift") for s in ("Discover/DiscoveryContracts","Discover/SeasonSchedule","Discover/SharedLink","Network/ArchiveNumber","Network/CardPreferenceMutation","Account/AccountRole","Account/AccountServices","Network/ServiceError","Decoder/AudioFilterChoice","Settings/DecodedSettingCache","Library/RecommendationFilter","Library/Video")]
    # Run the production signer with an OpenSSL MD5 leaf on Linux, and independently
    # pin each mutating request signature to the original Dart constants/encoding.
    (d/"MobileClientSigning.swift").write_text((src/"Account/MobileClientSigning.swift").read_text().replace("import CryptoKit", ""))
    constants=subprocess.check_output(["git","show","d9e9626f1a3f89cd9ca85e18f61aaba02634e12a:lib/common/constants.dart"],cwd=src.parents[2],text=True)
    appkey=re.search(r"appKey\s*=\s*'([^']+)'",constants)[1]
    appsec=re.search(r"appSec\s*=\s*'([^']+)'",constants)[1]
    expected={}
    for path,fields,action in [
        ("/x/feed/dislike",{"goto":"av","id":"45","feedback_id":"9","build":"1","mobi_app":"android"},"9"),
        ("/x/feed/dislike/cancel",{"goto":"av","id":"45","reason_id":"11","build":"1","mobi_app":"android"},"11"),
        ("/x/v2/view/dislike",{"aid":"45","dislike":"0"},"0"),
        ("/x/v2/view/dislike",{"aid":"45","dislike":"1"},"1"),
    ]:
        signed={**fields,"access_key":"local & test","appkey":appkey,"ts":"1700000000"}
        q="&".join(urllib.parse.quote(k,safe="-_.!~*'()")+"="+urllib.parse.quote(v,safe="-_.!~*'()") for k,v in sorted(signed.items()))
        expected[path+":"+action]=hashlib.md5((q+appsec).encode()).hexdigest()
    entries=",\n".join(json.dumps(k)+":"+json.dumps(v) for k,v in expected.items())
    (d/"SigningFixture.swift").write_text('''import Foundation
enum Insecure {enum MD5 {static func hash(data:Data)->[UInt8]{
  let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/openssl");p.arguments=["dgst","-md5","-binary"]
  let input=Pipe(),output=Pipe();p.standardInput=input;p.standardOutput=output;try! p.run()
  input.fileHandleForWriting.write(data);try! input.fileHandleForWriting.close()
  let bytes=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();precondition(p.terminationStatus==0);return Array(bytes)
}}}
enum CardPreferenceSignatureFixture {static let expected:[String:String]=[
'''+entries+'\n]}\n')
    files += [d/"MobileClientSigning.swift",d/"SigningFixture.swift"]
    if args.live:
        with ThreadPoolExecutor(max_workers=4) as pool:
            for key, value in pool.map(guest, routes.items()):
                (d/(key+".json")).write_text(json.dumps(value))
        for key,value in signed_searches():
            (d/(key+".json")).write_text(json.dumps(value))
    (d/"main.swift").write_text(r'''
import Foundation
try await CardPreferenceCheck.run()
var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:"America/New_York")!
let transition=cal.date(from:.init(year:2026,month:3,day:8,hour:12))!
var filters=VideoSearchOptions();filters.dates=1;filters.zone=167;filters.order="scores";filters.duration=3
let q=filters.fields(now:transition,calendar:cal)
precondition(Int(q["pubtime_end_s"]!)!-Int(q["pubtime_begin_s"]!)!+1==23*3600 && q["tids"]=="167" && q["order"]=="scores" && q["duration"]=="3")
filters.dates=7;let w=filters.fields(now:transition,calendar:cal);precondition(Int(w["pubtime_end_s"]!)!-Int(w["pubtime_begin_s"]!)!+1==7*86400-3600)
var more=OtherSearchOptions();more.userOrder=2;more.userType=3;more.articleZone=41;more.articleOrder="attention"
precondition(more.fields(.creator)==["order":"fans","order_sort":"1","user_type":"3"] && more.fields(.article)==["order":"attention","category_id":"41"] && more.fields(.live).isEmpty)
precondition(DiscoveryRanking.all.count==21 && VideoSearchOptions.zones.count==22 && Set(DiscoveryRanking.all).count==21)
let blocked:Set<Int64>=[900]
let v:[String:Any]=["aid":1234567,"title":"<em class=\"keyword\">A</em> &amp; B","mid":32,"duration":"1:02:03","play":103,"author":"UP","pic":"//i0.hdslb.com/cover"]
let vid=SearchHit.decode("video",v,blocked:blocked);guard case .video(let archive)=vid.first!.content else{fatalError()}
precondition(archive.aid==1234567 && archive.duration==3723 && archive.title=="A & B" && archive.stat?.view==103 && archive.owner?.mid==32)
let u:[String:Any]=["mid":"22","uname":"Name","is_live":1,"room_id":52,"res":[v],"fans":12]
let us=SearchHit.decode("bili_user",u,blocked:blocked);guard case .person(let p)=us.first!.content else{fatalError()}
precondition(p.room==52 && p.uploads.first?.id==archive.id && p.meta.contains("12"))
let blockedArticle=SearchHit.decode("article",["id":7,"mid":"900"],blocked:blocked);precondition(blockedArticle.isEmpty)
let c=SearchHit.decode("video",["type":"ketang","aid":48],blocked:blocked)
guard case .link(.course(48,false),_)=c.first!.content else{fatalError()}
precondition(SearchNumber.matched("1234567",rows:us+vid)==1234567 && SearchNumber.matched("1234567",rows:c+vid)==nil && SearchNumber.matched("42",rows:vid)==nil && SearchNumber.positive("1e4")==nil)
let matches=SearchHit.decode("esports",["contest":[["ID":28,"homeTeam":["title":"A"],"awayTeam":["title":"B"]]]],blocked:blocked)
guard case .link(.match(28),let card)=matches.first!.content,card.title=="A vs B" else{fatalError()}
print("Offline: DST windows; video, creator and article filters; rankings and zones; mixed search routing and blocked creators passed")
if CommandLine.arguments.count==2 {
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  func bytes(_ key:String)throws->Data{try Data(contentsOf:root.appendingPathComponent(key+".json"))}
  func object(_ key:String)throws->[String:Any]{try JSONSerialization.jsonObject(with:bytes(key)) as! [String:Any]}
  for key in ["anime","cinema"]{let c=try JSONDecoder().decode(SeasonIndexCondition.self,from:bytes(key));let defaults=c.firstChoices();precondition(!defaults.isEmpty && defaults["order"] != nil);print(key,"filter groups",c.filter?.count ?? 0,"ordering options",c.order?.count ?? 0)}
  let pages=try ["result1","result2"].map{try object($0)["list"] as! [[String:Any]]}
  let sections=pages.map{Set($0.compactMap{SearchHit.num($0["season_id"])})}
  precondition(sections.count==2 && !sections[0].isEmpty && !sections[1].isEmpty && sections[0] != sections[1]);print("index page rows",pages.map(\.count))
  for key in ["rank1","rank2"]{let d=try object(key);let n=(d["list"] as? [[String:Any]])?.count ?? 0;precondition(n>0);print(key,n)}
  let hot=try object("hot");print("trend slots",(hot["list"] as? [[String:Any]])?.count ?? 0,"pinned",(hot["top_list"] as? [[String:Any]])?.count ?? 0)
  let weeks=try object("weeks")["list"] as! [[String:Any]];precondition(!weeks.isEmpty);print("weekly editions",weeks.count)
  for kind in ["all","video","bili_user","article","media_bangumi","media_ft","live_room"] {
    let payload=try object("search-"+kind);let raw=payload["result"] as! [[String:Any]]
    let hits:[SearchHit]=kind=="all" ? raw.flatMap{g in (g["data"] as? [[String:Any]] ?? []).flatMap{SearchHit.decode(g["result_type"] as? String ?? "",$0,blocked:[])}}:raw.flatMap{SearchHit.decode(kind,$0,blocked:[])}
    precondition(!hits.isEmpty && SearchHit.num(payload["numResults"]) != nil)
    print("search",kind,"native hits",hits.count,"service total",SearchHit.num(payload["numResults"])!)
  }
  let sched=try ["timeline1","timeline4"].map{try JSONDecoder().decode([SeasonSchedule.Day].self,from:bytes($0))}
  let days=SeasonSchedule.merge(sched);precondition(days.contains{ $0.is_today==1 } && days.count>1);print("calendar days",days.count,"entries",days.reduce(0){$0+($1.episodes?.count ?? 0)})
}
''')
    subprocess.run(["swiftc",*(str(a) for a in files),str(Path(__file__).with_name("CardPreferenceCheck.swift")),str(d/"Creator.swift"),str(d/"main.swift"),"-o",str(d/"check")],check=True)
    subprocess.run([str(d/"check"),*([str(d)] if args.live else [])],check=True)
