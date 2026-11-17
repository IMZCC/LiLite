"""Read only public audio pages. Supply an AU with --song to bypass the directory lookup."""
import argparse,json,urllib.parse as q,urllib.request as u,urllib.error as er

def api(host,path,data):
    r=u.Request("https://"+host+path+"?"+q.urlencode(data),headers={"Referer":"https://www.bilibili.com/"})
    with u.urlopen(r,timeout=12) as f: response=json.load(f)
    code=response.get("code")
    if code!=0: raise RuntimeError(f"{path}: service code {code}")
    return response["data"]

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--space",type=int,default=3379951)
    p.add_argument("--song",type=int)
    a=p.parse_args();song=a.song
    if not song:
        d=api("api.bilibili.com","/audio/music-service/web/song/upper",dict(uid=a.space,pn=1,ps=20,order=1,web_location="333.1387"))
        rows=d.get("data") or []
        print("space",a.space,"returned",len(rows),"rows; total",d.get("totalSize"))
        if not rows: raise RuntimeError("No public song in this space")
        song=rows[0]["id"]
    s=api("www.bilibili.com","/audio/music-service-c/web/song/info",dict(sid=song))
    assert s.get("id")==song
    print("AU",song,"metadata: title",bool(s.get("title")),"cover",bool(s.get("cover")),"lyric",bool(s.get("lyric")),"linked video",bool(s.get("bvid")))
    data=api("www.bilibili.com","/audio/music-service-c/web/url",dict(sid=song,privilege=2,quality=2))
    cdns=data.get("cdns") or []
    print("audio sources returned",len(cdns))
    if not cdns: raise RuntimeError("No public audio source available")
    url=q.urlsplit(cdns[0])
    if url.scheme not in ("https","http") or not url.hostname: raise RuntimeError("No public HTTP source")
    r=u.Request(q.urlunsplit(url._replace(scheme="https")),headers={"Range":"bytes=0-511","Referer":"https://www.bilibili.com/audio/au"+str(song),"Accept-Encoding":"identity"})
    with u.urlopen(r,timeout=12) as f:
        count=len(f.read(512));print("public audio CDN",f.status,count,"bytes;",f.headers.get("Content-Range"))
        if f.status!=206 or count!=512: raise RuntimeError("CDN did not return requested range")
if __name__=="__main__":
    try: main()
    except (er.HTTPError,er.URLError,RuntimeError) as e:
        if isinstance(e,er.HTTPError): print("Public HTTP",e.code)
        else: print(e)
        raise SystemExit(1)
