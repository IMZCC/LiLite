"""Run synthetic backup compatibility tests in a temp directory against this process's loopback DAV server."""
from pathlib import Path
from tempfile import TemporaryDirectory
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from html import escape
import os, base64, hashlib, subprocess, sys, unicodedata, re, json
from urllib.parse import urlsplit, parse_qs
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

root=Path(__file__).resolve().parents[1]; src=root/'Sources/PiliNative'
def check():
    with TemporaryDirectory(prefix='pili-backup-fixture-') as temp:
        d=Path(temp); name='/PiliPlus/piliplus_settings_phone.json'; files={name:(b'original',1)}
        digest={'stores':{},'challenges':0,'requests':0}; sponsor=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args): pass
            def answer(self,status,body=b'',version=None):
                self.send_response(status); self.send_header('Content-Length',str(len(body)))
                if version: self.send_header('ETag','"'+str(version)+'"')
                self.end_headers()
                if self.command!='HEAD': self.wfile.write(body)
            def body(self):
                if not hasattr(self,'_body'):self._body=self.rfile.read(int(self.headers.get('Content-Length','0')))
                return self._body
            def allowed(self):
                assert not self.headers.get('Cookie') and not self.headers.get('Proxy-Authorization')
                if self.path.startswith('/digest'):
                    variant=self.path.split('/')[1]
                    self.digest_store=digest['stores'].setdefault(variant,{'body':b'digest-before','version':1})
                    nonce='renewed-synthetic-nonce' if self.digest_store.get('renewed') else 'fixed-synthetic-nonce'
                    algorithm='SHA-256' if 'sha256' in variant else 'MD5'
                    if variant.endswith('-sess'):algorithm+='-sess'
                    qop='auth-int' if variant.endswith('-authint') else 'auth'
                    header=self.headers.get('Authorization','')
                    fields=dict((key,quoted or bare) for key,quoted,bare in re.findall(r'(\w+)=(?:"([^"]*)"|([^,\s]+))',header))
                    digest_fn=hashlib.sha256 if algorithm.startswith('SHA') else hashlib.md5
                    md=lambda text:digest_fn(text.encode()).hexdigest()
                    a1=md('fixture:FixtureDAV:fake')
                    if algorithm.endswith('-sess'):a1=md(a1+':'+nonce+':'+fields.get('cnonce',''))
                    a2=md(self.command+':'+self.path+(':'+digest_fn(self.body()).hexdigest() if qop=='auth-int' else ''))
                    expected=md(':'.join([a1,nonce,fields.get('nc',''),fields.get('cnonce',''),qop,a2]))
                    valid=header.startswith('Digest ') and fields.get('username')=='fixture' and fields.get('uri')==self.path and fields.get('response')==expected
                    stale=valid and variant=='digest-stale' and not self.digest_store.get('renewed')
                    if not valid or stale:
                        if stale:self.digest_store['renewed']=True;nonce='renewed-synthetic-nonce'
                        self.body(); digest['challenges']+=1
                        self.send_response(401);self.send_header('WWW-Authenticate','Digest realm="FixtureDAV", nonce="'+nonce+'", algorithm='+algorithm+', qop="'+qop+'"'+(', stale=true' if stale else ''));self.send_header('Content-Length','0');self.end_headers();return False
                    digest['requests']+=1;return True
                if self.headers.get('Authorization')!='Basic '+base64.b64encode(b'fixture:fake').decode(): self.answer(403); return False
                return True
            def do_PROPFIND(self):
                if not self.allowed(): return
                if self.path.startswith('/digest'):
                    self.body()
                    self.answer(207,b'<D:multistatus xmlns:D="DAV:"><D:response><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>');return
                if self.path.rstrip('/')!='/PiliPlus': self.answer(404); return
                self.rfile.read(int(self.headers.get('Content-Length','0')))
                def row(href,prop):
                    return '<D:response><D:href>'+escape(href)+'</D:href><D:propstat><D:prop>'+prop+'</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>'
                parts=[row('/PiliPlus/','<D:resourcetype><D:collection/></D:resourcetype>')]
                if self.headers['Depth']=='1':
                    for k,(b,v) in files.items():
                        parts.append(row(k,f'<D:getcontentlength>{len(b)}</D:getcontentlength><D:getetag>"{v}"</D:getetag><D:resourcetype/>'))
                        parts.append(row(k.rsplit('/',1)[-1],f'<D:getetag>"{v}"</D:getetag>'))
                        parts.append(row('http://'+self.headers['Host']+k,f'<D:getetag>"{v}"</D:getetag>'))
                    for href in ['https://outside.invalid/PiliPlus/piliplus_settings_pad.json','/other/piliplus_settings_phone.json','/PiliPlus/unknown.txt','/PiliPlus/%2e%2e/PiliPlus/piliplus_settings_pad.json']:
                        parts.append(row(href,'<D:getetag>"fake"</D:getetag>'))
                self.answer(207,('<D:multistatus xmlns:D="DAV:">'+''.join(parts)+'</D:multistatus>').encode())
            def do_HEAD(self): self.do_GET()
            def do_GET(self):
                if self.path.startswith('/sponsor/api/'):
                    assert not self.headers.get('Authorization') and not self.headers.get('Cookie')
                    assert self.headers.get('Origin')=='PiliNative' and self.headers.get('X-Ext-Version')=='2.2.0.2'
                    route=urlsplit(self.path)
                    if route.path.endswith('/status/uptime'): self.answer(200,b'3600');return
                    assert route.path.endswith('/skipSegments') and parse_qs(route.query)=={'cid':['1'],'videoID':['BV-fixture']}
                    self.answer(200,b'[{"UUID":"fixture","segment":[1,2],"category":"sponsor","actionType":"skip"}]');return
                if not self.allowed(): return
                if self.path.startswith('/digest'):self.answer(200,self.digest_store['body'],self.digest_store['version']);return
                if self.path not in files: self.answer(404);return
                content,v=files[self.path]
                if self.headers.get('If-Match') not in (None,f'"{v}"'): self.answer(412);return
                self.answer(200,content,v)
            def do_PUT(self):
                if not self.allowed():return
                content=self.body()
                if self.path.startswith('/digest'):
                    assert self.headers.get('If-Match')=='"'+str(self.digest_store['version'])+'"' and content==b'digest-after'
                    self.digest_store['body']=content;self.digest_store['version']+=1;self.answer(204);return
                prev=files.get(self.path)
                if prev and self.headers.get('If-Match')!=f'"{prev[1]}"' or not prev and self.headers.get('If-None-Match')!='*':self.answer(412);return
                files[self.path]=(content,(prev[1]+1 if prev else 1));self.answer(204 if prev else 201)
            def do_DELETE(self):
                if not self.allowed():return
                prev=files.get(self.path)
                if not prev or self.headers.get('If-Match')!=f'"{prev[1]}"':self.answer(412);return
                del files[self.path];self.answer(204)
            def do_POST(self):
                assert self.path=='/sponsor/api/skipSegments' and not self.headers.get('Authorization') and not self.headers.get('Cookie')
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));assert body['userID']=='synthetic-private-service-id' and body['videoID']=='BV-fixture'
                sponsor.append(body);self.answer(200,b'[{"UUID":"fixture","segment":[1,2],"category":"sponsor","actionType":"skip"}]')
        srv=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=Thread(target=srv.serve_forever,daemon=True);thread.start()
        password=unicodedata.normalize('NFC','Synthetic跨设备-password-é').encode()
        payload=b'synthetic portable backup fixture only';salt=bytes(range(16));nonce=bytes(range(12))
        def key(s): return hashlib.pbkdf2_hmac('sha256',password,s,600000,32)
        head=b'PILIPACK'+b'\x01'+salt
        (d/'independent.pilipack').write_bytes(head+nonce+AESGCM(key(salt)).encrypt(nonce,payload,head))
        sources=[src/'Network/ServiceError.swift',src/'Network/SelfHostedServiceURL.swift',src/'Network/SelfHostedHTTPAuthentication.swift',src/'Playback/SponsorAPIRequest.swift',src/'Settings/BackupFormat.swift',src/'Settings/WebDAVStore.swift',src/'Settings/DataPackCipher.swift',src/'Settings/DataPackRestoreJournal.swift',src/'Social/ReplyArchive.swift',root/'Checks/BackupRecoveryCheck.swift']
        flags=[]
        if sys.platform.startswith('linux'):
            build=Path.home()/'.cache/piliplus-native/tools/crypto-storage/fixture/.build/debug'
            if not (build/'Crypto.o').is_file(): raise SystemExit('Build the pinned Apple swift-crypto compatibility fixture first: bash Checks/storage_locations.sh')
            flags=['-I',str(build),*map(str,[build/(n+'.o') for n in ('Crypto','CryptoBoringWrapper','CCryptoBoringSSL','CCryptoBoringSSLShims')]),'-lcrypto','-lstdc++']
        try:
            subprocess.run(['swiftc',*map(str,sources),*flags,'-o',str(d/'check')],check=True)
            subprocess.run([str(d/'check'),str(d),str(srv.server_port)],check=True,env={**os.environ,'NO_PROXY':'127.0.0.1','no_proxy':'127.0.0.1'})
            out=(d/'swift.pilipack').read_bytes()
            assert AESGCM(key(out[9:25])).decrypt(out[25:37],out[37:],out[:25])==payload
            assert files[name]==(b'new',2) and len(files)==2
            assert len(digest['stores'])==6 and all(item['body']==b'digest-after' for item in digest['stores'].values()) and digest['challenges']>=7 and digest['requests']>=24 and len(sponsor)==1
            print('Independent Python decode and untouched foreign paths passed')
        finally:
            srv.shutdown();srv.server_close();thread.join()
if __name__=='__main__':check()
