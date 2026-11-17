"""Loopback-only compatibility receiver. No LAN discovery, TV, account or public API is contacted."""
from pathlib import Path
import http.server, http.client, threading, socket, tempfile, subprocess, xml.etree.ElementTree as ET, urllib.parse as U, re
native=Path(__file__).resolve().parents[1];src=native/'Sources/PiliNative'
SOAP='http://schemas.xmlsoap.org/soap/envelope/';AV='urn:schemas-upnp-org:service:AVTransport:2';RC='urn:schemas-upnp-org:service:RenderingControl:1'
actionsA=['SetAVTransportURI','Play','Pause','Stop','Seek','GetPositionInfo','GetTransportInfo','GetCurrentTransportActions','GetMediaInfo']
actionsR=['GetVolume','SetVolume','GetMute','SetMute']
local=lambda t:t.rsplit('}',1)[-1]
modes={};logs=[];issues=[];ranges=[]
movie=bytearray((b"pili-"*600000)[:2600000]);movie[0:8]=bytes([0,0,0,24])+b"ftyp"
states={k:{'state':'STOPPED','uri':'','pos':0,'volume':70,'mute':0} for k in 'ab'}
def xml(code,body,svc):
    r=ET.Element('{'+SOAP+'}Envelope');b=ET.SubElement(r,'{'+SOAP+'}Body')
    if isinstance(body,int):
        f=ET.SubElement(b,'{'+SOAP+'}Fault');d=ET.SubElement(f,'detail');e=ET.SubElement(d,'UPnPError');ET.SubElement(e,'errorCode').text=str(body);ET.SubElement(e,'errorDescription').text='Rejected'
    else:
        act,fields=body;a=ET.SubElement(b,'{'+svc+'}'+act+'Response')
        for key,value in fields.items():ET.SubElement(a,key).text=str(value)
    return ET.tostring(r)
class Receiver(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a):pass
    def respond(self,status,b,headers=()):
        try:
            self.send_response(status);self.send_header('Content-Length',str(len(b)))
            for k,v in headers:self.send_header(k,v)
            self.end_headers();self.wfile.write(b)
        except (BrokenPipeError,ConnectionResetError):pass
    def do_GET(self):
        pieces=self.path.strip('/').split('/')
        try:
            assert not self.headers.get('Cookie') and not self.headers.get('Authorization')
            if pieces[0]=='media':
                r=self.headers.get('Range','');ranges.append((pieces[-1],r))
                if pieces[1]=='unavailable':return self.respond(502,b'unavailable')
                assert pieces[1]=='movie' and self.headers.get('Referer')==base+'/source'
                m=re.fullmatch(r'bytes=(\d+)-(\d+)',r);assert m
                a,b=map(int,m.groups());assert 0<=a<=b<len(movie) and b-a+1<=1024*1024
                return self.respond(206,movie[a:b+1],[('Content-Range',f'bytes {a}-{b}/{len(movie)}'),('Content-Type','video/mp4')])
            if pieces[0]=='fixture':modes[pieces[1]]=int(pieces[2]);return self.respond(200,b'ok')
            if pieces[0]=='redirect':return self.respond(302,b'',[('Location',base+'/a/device.xml')])
            if pieces[0]=='oversize':return self.respond(200,b'x'*560000)
            name,file=pieces
            if file=='device.xml':
                def svc(t,ep):return f'<service><serviceType>{t}</serviceType><controlURL>{ep}</controlURL><SCPDURL>{ep}.xml</SCPDURL></service>'
                body=f'<root xmlns="urn:schemas-upnp-org:device-1-0"><URLBase>{base}/{name}/</URLBase><device><deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType><UDN>uuid:receiver-{name}</UDN><friendlyName>家庭 &amp; TV</friendlyName><serviceList>{svc(AV,"av")}{svc(RC,"rc")}</serviceList></device></root>'
            else:
                actions=actionsA if file=='av.xml' else actionsR
                body='<scpd><actionList>'+''.join('<action><name>'+s+'</name></action>' for s in actions)+'</actionList><serviceStateTable><stateVariable><name>Volume</name><allowedValueRange><minimum>0</minimum><maximum>255</maximum><step>5</step></allowedValueRange></stateVariable></serviceStateTable></scpd>'
            return self.respond(200,body.encode())
        except Exception as e:issues.append(str(e));self.respond(500,b'')
    def do_POST(self):
        try:
            name,endpoint=self.path.strip('/').split('/');s=states[name];svc=AV if endpoint=='av' else RC
            if name=='b' and modes.get('downB'):return self.respond(503,b'unavailable')
            assert not self.headers.get('Cookie') and not self.headers.get('Authorization')
            request=ET.fromstring(self.rfile.read(int(self.headers['Content-Length'])));msg=list(request.find('{'+SOAP+'}Body'))[0];act=local(msg.tag)
            assert self.headers['SOAPAction']=='"'+svc+'#'+act+'"' and msg.tag=='{'+svc+'}'+act
            fields={local(e.tag):e.text or '' for e in msg};assert fields.pop('InstanceID')=='0'
            if endpoint=='rc':assert fields.pop('Channel')=='Master'
            logs.append((name,act,s['uri']))
            out={}
            if act=='SetAVTransportURI':
                uri=fields['CurrentURI'];meta=ET.fromstring(fields['CurrentURIMetaData'])
                assert uri.startswith(base+'/lease/') and '?' not in uri and meta.find('.//{*}res').text==uri and meta.find('.//{*}res').get('protocolInfo')=='http-get:*:video/mp4:*'
                assert meta.find('.//{*}title').text in ['A & B <测试>','第二集']
                s.update(uri=uri,state='STOPPED',pos=0)
            elif act=='Play':
                if name=='b' and (modes.get('failPlayB') or modes.pop('failOneB',0)):return self.respond(500,xml(500,701,svc))
                s['state']='PLAYING'
            elif act=='Pause':s['state']='PAUSED_PLAYBACK'
            elif act=='Stop':assert not modes.get('foreignA') or name!='a';s['state']='STOPPED'
            elif act=='Seek':
                assert fields['Unit']=='REL_TIME';h,m,sec=map(int,fields['Target'].split(':'));s['pos']=3600*h+60*m+sec
            elif act=='GetTransportInfo':out={'CurrentTransportState':s['state']}
            elif act=='GetPositionInfo':
                n=s['pos'];out={'TrackURI':'NOT_IMPLEMENTED' if modes.get('noTrackURI') else (base+'/other' if name=='a' and modes.get('foreignA') else s['uri']),'TrackDuration':'00:02:30','RelTime':f'{n//3600:02d}:{(n//60)%60:02d}:{n%60:02d}'}
            elif act=='GetCurrentTransportActions':out={'Actions':'Play,Pause,Stop,Seek'}
            elif act=='GetMediaInfo':out={'CurrentURI':base+'/other' if name=='a' and modes.get('foreignA') else s['uri']}
            elif act=='GetVolume':out={'CurrentVolume':s['volume']}
            elif act=='GetMute':out={'CurrentMute':s['mute']}
            elif act=='SetMute':s['mute']=int(fields['DesiredMute'])
            elif act=='SetVolume':s['volume']=int(fields['DesiredVolume']);assert s['volume']%5==0
            else:raise AssertionError(act)
            self.respond(200,xml(200,(act,out),svc))
        except Exception as e:issues.append(str(e));self.respond(500,b'')
with tempfile.TemporaryDirectory(prefix='pili-av-receiver-') as temp:
    exe=Path(temp)/'receiver'
    subprocess.run(['swiftc',*[str(src/'Playback'/(n+'.swift')) for n in ['CastProtocol','CastBonjourLocation','CastHTTP','CastDiscovery','CastGrant','CastSession','ArchiveStreamGrant']],str(src/'Network/ServerCertificatePolicy.swift'),str(src/'Network/ArchiveNumber.swift'),str(native/'Checks/CastReceiverCheck.swift'),'-o',str(exe)],check=True)
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Receiver);base=f'http://127.0.0.1:{server.server_port}'
    threading.Thread(target=server.serve_forever,daemon=True).start()
    udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);udp.bind(('127.0.0.1',0));udp.settimeout(4)
    def announce():
        q,addr=udp.recvfrom(4096);assert addr[0]=='127.0.0.1' and b'M-SEARCH' in q
        root='urn:schemas-upnp-org:device:MediaRenderer:1';usn='uuid:receiver-a::'+root
        for location in [base+'/a/device.xml',base+'/a/device.xml','http://203.0.113.10/foreign']:
            udp.sendto(f'HTTP/1.1 200 OK\r\nST: {root}\r\nUSN: {usn}\r\nLOCATION: {location}\r\nCACHE-CONTROL: max-age=120\r\n\r\n'.encode(),addr)
        udp.sendto(f'NOTIFY * HTTP/1.1\r\nNT: {root}\r\nNTS: ssdp:byebye\r\nUSN: {usn}\r\n\r\n'.encode(),addr)
    threading.Thread(target=announce,daemon=True).start()
    try:
        subprocess.run([str(exe),base,str(udp.getsockname()[1])],check=True,timeout=48)
        relay=Path(temp)/'relay'
        subprocess.run(['swiftc',*[str(src/'Playback'/(n+'.swift')) for n in ['CastRelayHTTP','CastMediaSource','RangeTransport','RelayRange','MediaRange']],str(src/'Network/ServerCertificatePolicy.swift'),str(native/'Checks/CastRelayFixture.swift'),'-o',str(relay)],check=True)
        proc=subprocess.Popen([str(relay),base],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            port=int(proc.stdout.readline())
            def exchange(method,path,expect,headers=(),want=None):
                h=http.client.HTTPConnection('127.0.0.1',port,timeout=5);h.putrequest(method,path)
                for k,v in headers:h.putheader(k,v)
                h.endheaders();r=h.getresponse();data=r.read();fields=dict(r.getheaders());h.close()
                assert r.status==expect,(path,r.status,expect)
                if want is not None:assert data==want
                return fields
            path='/fixture/video.mp4';head=exchange('HEAD',path,200,want=b'')
            assert int(head['Content-Length'])==len(movie) and head['Content-Type']=='video/mp4' and 'DLNA.ORG_OP=01' in head['contentFeatures.dlna.org']
            part=exchange('GET',path,206,[('Range','bytes=901-2200900')],movie[901:2200901])
            assert part['Content-Range']==f'bytes 901-2200900/{len(movie)}'
            exchange('GET',path,206,[('Range','bytes=-32')],movie[-32:])
            exchange('GET',path,200,want=movie)
            exchange('GET',path,416,[('Range','bytes=0-1'),('Range','bytes=4-5')])
            exchange('GET',path,416,[('Range',f'bytes={len(movie)}-')])
            exchange('POST',path,405)
            exchange('GET','/fixture/other',404)
            exchange('GET','/fixture/revoke',404)
            exchange('HEAD',path,403,want=b'')
            assert proc.wait(timeout=5)==0
            assert ranges[0][0]=='unavailable' and all(n=='movie' for n,_ in ranges[1:])
            print('Loopback HTTP relay: 2.6 MB exact GET + 2.2 MB seek bounded to 1 MiB origin reads; HEAD, suffix, 416, 405, wrong token, mirror and revoked HEAD passed')
        finally:
            if proc.poll() is None:proc.terminate();proc.wait(timeout=3)
    finally:server.shutdown();server.server_close();udp.close()
    assert not issues,issues
    assert any(k=='a' and a=='Pause' and '/first.' in u for k,a,u in logs)
    assert len([1 for _,a,_ in logs if a=='Stop'])==1
    print(f'{len(logs)} captured local SOAP exchanges; no credentials, remote media URLs or foreign Stop commands')
