#!/usr/bin/env python3
"""Local TLS/DAV fixtures, no public network, Apple accounts or installed root certificates. Requires OpenSSL and swiftc."""
import datetime
import http.server
import os
from pathlib import Path
import select
import shutil
import socket
import socketserver
import ssl
import subprocess
import tempfile
import threading

NATIVE = Path(__file__).resolve().parents[1]
SRC = NATIVE / "Sources/PiliNative"


def run(*args):
    return subprocess.run([str(x) for x in args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def identity(path):
    def cmd(*args):
        r = subprocess.run(["openssl", *map(str,args)], cwd=path, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if r.returncode: raise RuntimeError(r.stderr.decode())
    def key(name):
        cmd("req","-new","-nodes","-newkey","rsa:2048","-subj","/CN="+name,"-out",name+".csr","-keyout",name+".key")
    # Virtualized test clocks can step during startup. Backdate the valid fixture,
    # instead of weakening the TLS verifier; the expired certificate stays expired.
    now=datetime.datetime.now(datetime.timezone.utc)
    start=(now-datetime.timedelta(days=1)).strftime("%y%m%d%H%M%SZ")
    end=(now+datetime.timedelta(days=3)).strftime("%y%m%d%H%M%SZ")
    for n in ["ca","other"]:
        key(n)
        (path/(n+".idx")).touch(); (path/(n+".serial")).write_text("01\n")
        (path/(n+".cnf")).write_text(
            "[ca]\ndefault_ca=c\n[c]\ndatabase="+n+".idx\nserial="+n+".serial\nnew_certs_dir=.\n"
            "default_md=sha256\npolicy=p\n[p]\ncommonName=supplied\n[root]\n"
            "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n")
        cmd("ca","-batch","-selfsign","-notext","-config",n+".cnf","-keyfile",n+".key","-extensions","root",
            "-startdate",start,"-enddate",end,"-in",n+".csr","-out",n+".pem")
    (path/"index").touch(); (path/"serial").write_text("10\n")
    (path/"issuer.cnf").write_text(
        "[ca]\ndefault_ca=local\n[local]\ndatabase=index\nserial=serial\nnew_certs_dir=.\n"
        "certificate=ca.pem\nprivate_key=ca.key\ndefault_md=sha256\npolicy=policy\n"
        "default_days=2\n[policy]\ncommonName=supplied\n")
    for n,san in [("localhost","DNS:localhost,IP:127.0.0.1,IP:::1,DNS:*.fixture.test"),
                  ("wrong","DNS:wrong.test"),("expired","DNS:localhost")]:
        key(n)
        (path/"leaf.cnf").write_text("basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName="+san+"\n")
        args=["-startdate",start,"-enddate",end]
        if n=="expired":
            now=datetime.datetime.now(datetime.timezone.utc)
            args=["-startdate",(now-datetime.timedelta(days=2)).strftime("%y%m%d%H%M%SZ"),
                  "-enddate",(now-datetime.timedelta(hours=1)).strftime("%y%m%d%H%M%SZ")]
        cmd("ca","-batch","-notext","-config","issuer.cnf","-extfile","leaf.cnf","-in",n+".csr","-out",n+".pem",*args)


class DAV(http.server.BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def log_message(self,*_): pass
    def response(self,status,body=b"",fields=()):
        self.send_response(status);self.send_header("Content-Length",str(len(body)));self.send_header("Connection","close")
        for k,v in fields:self.send_header(k,v)
        self.end_headers();self.wfile.write(body);self.close_connection=True
    def handle_one_request(self):
        try: super().handle_one_request()
        except (ConnectionResetError,ssl.SSLError): pass
    def auth(self):
        assert self.connection.selected_alpn_protocol()=="http/1.1" and self.request_version=="HTTP/1.1"
        assert self.headers.get("Proxy-Authorization") is None
        assert self.headers.get("Host")=="localhost:"+str(self.server.server_port)
        if self.path.startswith("/dav/"):
            assert self.headers.get("Authorization")=="Basic Zml4dHVyZTp0ZXN0LW9ubHk=" and not self.headers.get("Cookie")
    def do_GET(self):
        self.auth()
        if self.path=="/api/item?q=a%2Fb":
            assert self.headers.get("Cookie")=="fixture=synthetic" and self.headers.get("Accept-Encoding")=="identity"
            self.server.events.append("REST");self.response(200,b"direct")
        else:
            assert self.path=="/dav/fixture.json"
            self.server.events.append("GET");self.response(200,self.server.body,[("ETag",'"fixture"')])
    def do_PROPFIND(self):
        self.auth();assert self.path in ("/dav/","/dav") and self.headers.get("Depth")=="0"
        assert b"resourcetype" in self.rfile.read(int(self.headers["Content-Length"]))
        self.server.events.append("PROPFIND");self.response(207,b'<d:multistatus xmlns:d="DAV:"><d:response><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>')
    def do_PUT(self):
        self.auth();assert self.path=="/dav/fixture.json" and self.headers.get("If-Match")=='"fixture"'
        self.server.body=self.rfile.read(int(self.headers["Content-Length"])); assert self.server.body==b"after"
        self.server.events.append("PUT"); self.response(204)


class Tunnel(socketserver.StreamRequestHandler):
    def handle(self):
        target="localhost:"+str(self.server.origin)
        first=self.rfile.readline(1024).decode().strip()
        assert first in ["CONNECT "+target+" HTTP/1.0","CONNECT "+target+" HTTP/1.1"]
        lines=[]
        while True:
            line=self.rfile.readline(4096)
            if line in (b"",b"\r\n"): break
            lines.append(line.lower())
        assert all(b"authorization:" not in x and b"cookie:" not in x for x in lines)
        with socket.create_connection(("127.0.0.1",self.server.origin),3) as dest:
            self.wfile.write(b"HTTP/1.1 200 Connection established\r\n\r\n"); self.wfile.flush()
            self.server.events.append("CONNECT")
            while True:
                ready,_,_=select.select([self.connection,dest],[],[],8)
                if not ready:return
                for src in ready:
                    buf=src.recv(65536)
                    if not buf:return
                    (dest if src is self.connection else self.connection).sendall(buf)


class CloseTLS(http.server.ThreadingHTTPServer):
    def shutdown_request(self, request):
        try:
            request.settimeout(2); plain=request.unwrap()
        except (OSError,ValueError):
            super().shutdown_request(request)
        else:
            super().shutdown_request(plain)

def tlsserver(path,name):
    srv=CloseTLS(("127.0.0.1",0),DAV)
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.minimum_version=ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(path/(name+".pem"),path/(name+".key"));ctx.set_alpn_protocols(["h2","http/1.1"])
    srv.socket=ctx.wrap_socket(srv.socket,server_side=True);srv.events=[];srv.body=b"before";start(srv)
    return srv


def start(srv):
    threading.Thread(target=srv.serve_forever,daemon=True).start()


def handshake(server,ca,hostname,alpn):
    ctx=ssl.create_default_context(cafile=str(ca));ctx.set_alpn_protocols(alpn)
    with socket.create_connection(("127.0.0.1",server.server_port),3) as sock:
        with ctx.wrap_socket(sock,server_hostname=hostname) as tls:
            return tls.selected_alpn_protocol()


def main():
    swift=shutil.which("swiftc")
    if not swift: raise SystemExit("Set PATH to the Swift toolchain")
    with tempfile.TemporaryDirectory(prefix="pili-net-") as d:
        path=Path(d);identity(path)
        run(swift,SRC/"Network/ServiceError.swift",SRC/"Network/ConnectionRetry.swift",SRC/"Network/HTTP11Message.swift",
            SRC/"Network/ServerCertificate.swift",SRC/"Network/ServerCertificatePolicy.swift",SRC/"Network/SelfHostedServiceURL.swift",SRC/"Settings/BackupFormat.swift",SRC/"Settings/WebDAVStore.swift",NATIVE/"Checks/SecureNetworkCheck.swift","-o",path/"check")
        live=tlsserver(path,"localhost");wrong=tlsserver(path,"wrong");expired=tlsserver(path,"expired")
        proxy=socketserver.ThreadingTCPServer(("127.0.0.1",0),Tunnel);proxy.origin=live.server_port;proxy.events=[];start(proxy)
        try:
            assert handshake(live,path/"ca.pem","localhost",["h2","http/1.1"])=="h2"
            assert handshake(live,path/"ca.pem","localhost",["http/1.1"])=="http/1.1"
            for server,ca,host,why in [(live,"other","localhost","unrelated CA"),(live,"ca","wrong.test","wrong requested host"),
                    (wrong,"ca","localhost","wrong server SAN"),(expired,"ca","localhost","expired leaf")]:
                try: handshake(server,path/(ca+".pem"),host,["http/1.1"])
                except ssl.SSLCertVerificationError: pass
                else: raise AssertionError(why)
            child=subprocess.run([str(path/"check"),str(path),str(live.server_port),str(proxy.server_address[1])],timeout=35)
            assert child.returncode==0
            assert live.events==["REST","PROPFIND","GET","PUT","GET"] and proxy.events==["CONNECT"]*4
            print("TLS loopback: ALPN h2 and HTTP/1.1; 4 trust rejections; 1 direct REST and 4 tunneled DAV requests")
        finally:
            for srv in [proxy,live,wrong,expired]:srv.shutdown();srv.server_close()

if __name__=="__main__":main()
