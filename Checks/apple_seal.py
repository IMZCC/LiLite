"""Verify an xtool development archive's executable, resource seal and profile-authorized signer."""
import hashlib, os, plistlib, ssl, struct, subprocess, tempfile
from pathlib import Path, PurePosixPath

def ensure(ok, label):
    if not ok: raise ValueError("Apple development signature: "+label)

def commands(blob):
    offset=32
    for _ in range(struct.unpack_from("<I",blob,16)[0]):
        tag,length=struct.unpack_from("<II",blob,offset)
        ensure(length>=8 and offset+length<=len(blob),"load command")
        if tag==0x1d:
            off,sz=struct.unpack_from("<II",blob,offset+8)
            ensure(0<off<=len(blob)-sz,"signature extent")
            return off,blob[off:off+sz]
        offset+=length
    raise ValueError("Missing executable signature")

def parts(superblob):
    magic,size,count=struct.unpack_from(">III",superblob)
    ensure(magic==0xfade0cc0 and 12+count*8<=size<=len(superblob),"signature directory")
    out={}
    for i in range(count):
        slot,at=struct.unpack_from(">II",superblob,12+8*i)
        ensure(slot not in out and 12+count*8<=at<=size-8,"overlapping signature index")
        _,n=struct.unpack_from(">II",superblob,at)
        ensure(8<=n<=size-at,"signature slot extent")
        out[slot]=superblob[at:at+n]
    return out

def verify_development(z,prefix,profile):
    info=z.read(prefix+"Info.plist"); binary=z.read(prefix+plistlib.loads(info)["CFBundleExecutable"])
    sig_at,sig=commands(binary);slots=parts(sig)
    manifest=z.read(prefix+"_CodeSignature/CodeResources")
    ensure(0 in slots and 0x10000 in slots,"missing signed directory")
    for t,cd in slots.items():
        if t!=0 and not (0x1000<=t<=0x1005):continue
        magic,sz,ver,_,hashat,_,ns,num,limit=struct.unpack_from(">9I",cd)
        hlen,alg,_,page=struct.unpack_from("4B",cd,36)
        algorithm={1:"sha1",2:"sha256",3:"sha256",4:"sha384"}.get(alg)
        ensure(magic==0xfade0c02 and ver>=0x20001 and algorithm and 0<page<=20,"unsupported code directory")
        if limit==0 and ver>=0x20300:limit=struct.unpack_from(">Q",cd,56)[0]
        ensure(limit==sig_at and num==((limit+(1<<page)-1)>>page),"unsigned executable content")
        ensure(hlen==({1:20,2:32,3:20,4:48}[alg]) and hashat>=ns*hlen and hashat+num*hlen<=sz,"invalid hash table")
        def check(i,src):
            at=hashat+i*hlen
            ensure(cd[at:at+hlen]==hashlib.new(algorithm,src).digest()[:hlen],"hash mismatch at slot "+str(i))
        for i in range(num):check(i,binary[i<<page:min((i+1)<<page,limit)])
        for i,payload in {1:info,2:slots.get(2),3:manifest,5:slots.get(5),7:slots.get(7)}.items():
            if payload is not None:
                ensure(i<=ns,"unsealed special slot "+str(i));check(-i,payload)
    with tempfile.TemporaryDirectory() as temp:
        d=Path(temp);cd=d/"directory";cd.write_bytes(slots[0]);signer=d/"signer.pem"
        subprocess.run(["openssl","cms","-verify","-binary","-noverify","-inform","DER","-content",str(cd),
                        "-signer",str(signer),"-out",os.devnull],input=slots[0x10000][8:],stderr=subprocess.PIPE,check=True)
        pem=signer.read_text()
        ensure(pem.count("BEGIN CERTIFICATE")==1 and ssl.PEM_cert_to_DER_cert(pem) in profile.get("DeveloperCertificates",[]),
               "signer is not authorized by the included development profile")
    resource_list=plistlib.loads(manifest)
    for kind in ("files","files2"):
        records=resource_list.get(kind,{})
        for name,attrs in records.items():
            path=PurePosixPath(name)
            ensure(not path.is_absolute() and ".." not in path.parts and "\\" not in name,"resource path")
            if isinstance(attrs,bytes):attrs={"hash":attrs}
            if attrs.get("optional") and prefix+name not in z.namelist():continue
            content=z.read(prefix+name)
            hashes=[(key,algo) for key,algo in (("hash","sha1"),("hash2","sha256")) if key in attrs]
            ensure(hashes and all(hashlib.new(algo,content).digest()==attrs[key] for key,algo in hashes),"changed resource "+name)
