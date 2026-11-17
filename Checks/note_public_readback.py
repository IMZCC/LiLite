"""Optional, anonymous: public notes, a CV redirect and a rendered math expression; no accounts or writes."""
import json, pathlib, subprocess, tempfile, urllib.parse, urllib.request
root=pathlib.Path(__file__).resolve().parents[1]
def request(url, method="GET"):
    return urllib.request.urlopen(urllib.request.Request(url,method=method,headers={"Referer":"https://www.bilibili.com/","User-Agent":"Mozilla/5.0"}),timeout=12)
def api(path, fields):
    with request("https://api.bilibili.com"+path+"?"+urllib.parse.urlencode(fields)) as response:
        envelope=json.load(response)
        if envelope["code"]!=0: raise RuntimeError((path,envelope["code"],envelope.get("message")))
        return envelope["data"]
rows=api("/x/note/publish/list/archive",{"oid":170001,"oid_type":0,"pn":1,"ps":10})
if not rows.get("list"): raise RuntimeError("No public note on the sample archive")
cv=rows["list"][0]["cvid"]
article=api("/x/note/publish/info",{"cvid":cv})
assert int(article["cvid"])==int(cv) and int(article["arc"]["oid"])==170001 and int(article["pub_status"])==2
print("Public note total:",rows.get("page",{}).get("total"),flush=True)
with request(f"https://www.bilibili.com/read/cv{cv}/","HEAD") as response:
    print("Resolved CV path:",urllib.parse.urlparse(response.geturl()).path,flush=True)
with request("https://api.bilibili.com/x/web-frontend/mathjax/tex?formula="+urllib.parse.quote("a^2+b^2=c^2")) as r:
    assert r.headers.get_content_type()=="image/svg+xml" and b"<svg" in r.read(1024)
with tempfile.TemporaryDirectory() as tmp:
    sample=pathlib.Path(tmp,"public.json");sample.write_text(json.dumps(article),encoding="utf-8")
    subprocess.run(["bash",str(root/"Checks/notebook_domain.sh"),str(sample)],cwd=root,check=True)
