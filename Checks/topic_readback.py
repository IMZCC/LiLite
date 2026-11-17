# Optional network check: anonymous GET only, using a public topic from the upstream router examples.
from pathlib import Path
import urllib.request,urllib.parse, json,subprocess,tempfile
src=Path(__file__).resolve().parents[1]/"Sources/PiliNative"
def read(path): return (src/path).read_text()
def query(host,route,q):
    url="https://"+host+route+"?"+urllib.parse.urlencode(q)
    req=urllib.request.Request(url,headers={"User-Agent":"Mozilla/5.0","Referer":"https://www.bilibili.com/"})
    with urllib.request.urlopen(req,timeout=12) as f:ret=json.load(f)
    assert ret["code"]==0,(route,ret.get("code"))
    return ret.get("data")
with tempfile.TemporaryDirectory() as tmp:
    d=Path(tmp)
    def store(name,txt): p=d/name;p.write_text(txt);return str(p)
    service=read("Social/TopicService.swift")
    files=[
        store("Topic.swift",service.split("extension BiliAPI {",1)[0]+"\nstruct TopicAddress {"+service.split("struct TopicAddress {",1)[1]),
        store("Dynamic.swift",read("Network/DynamicAPI.swift").split("extension BiliAPI {",1)[0]),
        store("Preview.swift",read("Network/CollectionsAPI.swift").split("extension BiliAPI {",1)[0])]
    files += [str(src/(i+".swift")) for i in ("Network/ServiceError","Decoder/AudioFilterChoice","Library/GalleryPicture","Settings/DecodedSettingCache","Library/RecommendationFilter","Library/Video","Discover/SharedLink","Social/ReplyAuthor","Social/DynamicModules","Social/MomentResources","Social/RichNodes")]
    # Use the same feature string as the app, and never forward credentials.
    features=service.split('fields["features"] = "',1)[1].split('"',1)[0]
    tid="1028161"
    recommend=query("api.bilibili.com","/x/topic/web/dynamic/rcmd",{"page_size":"25","source":"Web","web_location":"333.1365"})
    print("recommendation envelope:",type(recommend).__name__,flush=True)
    top=query("app.bilibili.com","/x/topic/web/details/top",{"topic_id":tid,"source":"Web"})
    page=query("api.bilibili.com","/x/polymer/web-dynamic/v1/feed/topic",{"topic_id":tid,"sort_by":"0","page_size":"20","source":"Web","features":features})
    fold=query("api.bilibili.com","/x/topic/web/details/fold",{"topic_id":tid,"sort_by":"0"})
    allpages=[top["top_details"],page,fold]
    for i,p in enumerate(allpages): store(str(i)+".json",json.dumps(p))
    files.append(store("main.swift",'''import Foundation
let home = URL(fileURLWithPath: CommandLine.arguments[1])
func data(_ i: Int) throws -> Data { try Data(contentsOf: home.appendingPathComponent("\\(i).json")) }
let top = try JSONDecoder().decode(TopicHeader.self,from:data(0))
precondition(top.topic_item?.id == 1028161 && top.topic_creator?.uid != nil)
func page(_ i: Int) throws -> TopicPage {
  TopicPage(try JSONSerialization.jsonObject(with:data(i)) as! [String:Any],cursor:nil)
}
let p=try page(1), f=try page(2)
precondition(p.cards.count > 0 && f.cards.count > 0)
precondition(p.sorts?.contains(where: { $0.id == 2 && $0.name == "热门" }) == true)
let join = f.expand("placeholder",in:[p.cards[0],.fold("placeholder","展开")])
precondition(join.first?.id == p.cards[0].id && !join.contains(where: { $0.id=="placeholder" }))
precondition(Set(join.map(\\.id)).count == join.count)
precondition(SharedLink.parse(TopicAddress.share(1028161).absoluteString) == .topic(1028161))
let report = TopicAddress.report(1028161,name:"A&B #中文",dark:true)!
precondition(URLComponents(url:report,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="topic_name"})?.value == "A&B #中文")
print("Native parsed public topic \\(top.topic_item!.id): \\(p.cards.count) cards, \\(f.cards.count) folded cards, \\(join.count) unique after replacement")
'''))
    subprocess.run(["swiftc",*files,"-o",str(d/"check")],check=True)
    subprocess.run([str(d/"check"),str(d)],check=True)
