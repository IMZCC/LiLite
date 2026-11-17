"""Read-only delivery checks for the reviewed unsigned IPA and the signed personal-device IPA."""
import base64
import hashlib
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import subprocess
import tempfile
import ssl
import time
import zipfile
from review_receipts import NATIVE, STAMP, info, is_hash, require, revision_fingerprint, sha_file
from inspect_ipa import executable_entitlements, application_identity

# DER fingerprints of the three roots published by https://www.apple.com/certificateauthority/
ROOT_DIGESTS={
    "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
    "c2b9b042dd57830e7d117dac55ac8ae19407d38e41d88f3215bc3a890444a050",
    "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
}
def profile_issued_by_apple(cms):
    anchor=NATIVE/"Checks/trust/apple-profile-roots.pem"
    roots=re.findall(rb"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----",anchor.read_bytes(),re.S)
    require(len(roots)==3 and {hashlib.sha256(base64.b64decode(b"".join(x.split()),validate=True)).hexdigest() for x in roots}==ROOT_DIGESTS,"Apple profile trust anchors differ")
    with tempfile.TemporaryDirectory(prefix="pili-profile-issuer-") as t:
        signer=Path(t)/"public-signer.pem"
        result=subprocess.run(["openssl","cms","-verify","-inform","DER","-purpose","any","-CAfile",str(anchor),"-no-CApath","-no-CAstore","-signer",str(signer)],input=cms,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        require(result.returncode==0 and signer.is_file(),"Provisioning profile CMS does not chain to an Apple root")
        require(signer.read_bytes().count(b"-----BEGIN CERTIFICATE-----")==1,"Ambiguous profile signer")
        cert=subprocess.check_output(["openssl","x509","-in",str(signer),"-text","-noout"],encoding="utf-8")
        require(re.search(r"^\s*1\.2\.840\.113635\.100\.6\.58:\s*(?:critical)?\s*$",cert,re.M),"Signer lacks Apple's provisioning profile signing purpose")
        return plistlib.loads(result.stdout)

def development_certificate(binary,profile):
    # The Apple-signed profile authorizes the leaf. Check that the actual detached CMS
    # uses that current development certificate, including its dates and signing purpose.
    from apple_seal import commands,parts
    slots=parts(commands(binary)[1])
    with tempfile.TemporaryDirectory(prefix="pili-developer-leaf-") as t:
        directory=Path(t)/"directory";directory.write_bytes(slots[0])
        signer=Path(t)/"signer.pem"
        subprocess.run(["openssl","cms","-verify","-binary","-noverify","-inform","DER","-content",str(directory),
                        "-signer",str(signer),"-out",str(Path(t)/"verified-directory")],
                       input=slots[0x10000][8:],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,check=True)
        pem=signer.read_text(encoding="ascii")
        require(pem.count("BEGIN CERTIFICATE")==1 and ssl.PEM_cert_to_DER_cert(pem) in profile.get("DeveloperCertificates",[]),
                "Actual code signer is not authorized by this Apple-issued profile")
        text=subprocess.check_output(["openssl","x509","-in",str(signer),"-text","-noout"],encoding="utf-8")
        dates=subprocess.check_output(["openssl","x509","-in",str(signer),"-startdate","-enddate","-noout"],encoding="ascii")
        values=dict(line.split("=",1) for line in dates.splitlines())
        now=time.time()
        require(ssl.cert_time_to_seconds(values["notBefore"])<=now<ssl.cert_time_to_seconds(values["notAfter"]),
                "The development signing certificate is not currently valid")
        require("Code Signing" in text and re.search(r"^\s*1\.2\.840\.113635\.100\.6\.1\.(?:2|12):",text,re.M),
                "Expected an Apple development code-signing certificate")

def personal_entitlements(actual,allowed):
    require(set(actual)=={"application-identifier","com.apple.developer.team-identifier","get-task-allow","keychain-access-groups"},
            "Unexpected entitlement in a personal-device build")
    require(actual["get-task-allow"] is True and allowed.get("get-task-allow") is True,"Expected device-development debugging authorization")
    groups=actual["keychain-access-groups"];patterns=allowed.get("keychain-access-groups",[])
    require(isinstance(groups,list) and groups and isinstance(patterns,list) and patterns
            and all(isinstance(g,str) and any(isinstance(p,str) and (g==p or p.endswith(".*") and g.startswith(p[:-1])) for p in patterns) for g in groups),
            "Profile does not authorize the app's keychain groups")
def for_device(profile, udid):
    normalized=udid.lower() if isinstance(udid,str) else ""
    require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{8}-[0-9a-f]{16}",normalized),"Supply the target iPhone UDID")
    ids=profile.get("ProvisionedDevices")
    require(isinstance(ids,list) and normalized in {s.lower() for s in ids if isinstance(s,str)},"Target iPhone is not covered by this provisioning profile")
    require(not profile.get("ProvisionsAllDevices") and "iOS" in profile.get("Platform",[]) and profile.get("Entitlements",{}).get("get-task-allow") is True,"Expected an iOS device development profile")
def digest(data):return hashlib.sha256(data).hexdigest()
def executable_digest(binary):
    require(len(binary)>=32 and struct.unpack_from("<II",binary)==(0xfeedfacf,0x0100000c),"Expected arm64 Mach-O")
    header=bytearray(binary[:32]);n,cmdbytes=struct.unpack_from("<II",header,16)
    require(0<n<2000 and 32+cmdbytes<=len(binary),"Invalid release image")
    at=32;cmds=[];first=len(binary);end=len(binary);sign=False;linkedit=False
    for _ in range(n):
        tag,size=struct.unpack_from("<II",binary,at)
        require(size>=8 and at+size<=32+cmdbytes,"Invalid load command")
        command=bytearray(binary[at:at+size]);at+=size
        if tag==0x1d:
            require(not sign and size==16,"Unexpected signature load command")
            off,count=struct.unpack_from("<II",command,8)
            require(count>0 and off>=at and off+count==len(binary),"Signature is not the final executable region")
            end=off;sign=True;continue
        if tag==0x19:
            require(size>=72,"Truncated segment");name=bytes(command[8:24]).rstrip(b"\0")
            pos,length=struct.unpack_from("<QQ",command,40)
            require(pos+length<=len(binary),"Invalid segment size")
            nsections=struct.unpack_from("<I",command,64)[0];require(72+80*nsections==size,"Invalid segment sections")
            if pos>0 and length:first=min(first,pos)
            for i in range(nsections):
                offset=struct.unpack_from("<I",command,72+80*i+48)[0]
                if offset>0:first=min(first,offset)
            if name==b"__LINKEDIT":
                require(not linkedit and pos+length==len(binary),"Unexpected signing segment")
                linkedit=True
                # Re-signing changes only the two sizes covering the final signature, not the VM/file offset.
                command[32:40]=b"\0"*8;command[48:56]=b"\0"*8
        cmds.append(command)
    require(at==32+cmdbytes and at<=first<=end and not any(binary[at:first]) and linkedit,"Invalid Mach-O header padding")
    struct.pack_into("<II",header,16,len(cmds),sum(map(len,cmds)))
    h=hashlib.sha256();h.update(header)
    for c in cmds:h.update(c)
    # Include all load commands, original section offsets and all executable/linker bytes, excluding signing alignment.
    tail=binary[first:end];pad=min(15,len(tail)-len(tail.rstrip(b"\0")))
    h.update(struct.pack("<Q",first));h.update(tail[:-pad] if pad else tail)
    return h.hexdigest()
def bundle_payload(ipa,signed=False):
    i,p=info(ipa); files={}
    require(isinstance(i.get(STAMP),str),"Unstamped release IPA")
    with zipfile.ZipFile(ipa) as z:
        if signed:
            from apple_seal import verify_development
            profile=profile_issued_by_apple(z.read(p+"embedded.mobileprovision"))
            verify_development(z,p,profile)
            canonical_identity=application_identity(i,executable_entitlements(z.read(p+i["CFBundleExecutable"])),profile)
        else:canonical_identity=application_identity(i)
        count=0;total=0
        for member in z.infolist():
            if member.is_dir():continue
            name=member.filename
            require(name.startswith(p) and "\\" not in name and "//" not in name and str(PurePosixPath(name))==name and ".." not in PurePosixPath(name).parts,"Unexpected member in IPA")
            require((member.external_attr>>16)&0o170000 != 0o120000,"Unexpected symlink in IPA")
            key=name[len(p):]
            if key=="embedded.mobileprovision" or key=="_CodeSignature/CodeResources":continue
            if key=="Info.plist":
                normal=dict(i)
                # These fields are independently verified; a later build may be stamped after review.
                del normal[STAMP];normal.pop("PiliNativeBuildDate",None)
                # Personal-team prefix was independently matched to the real signing team above.
                normal["CFBundleIdentifier"]=canonical_identity
                files[key]=digest(plistlib.dumps(normal,sort_keys=True))
            else:
                count+=1;total+=member.file_size
                require(count<=10000 and total<=2*1024**3 and member.file_size<=512*1024**2,"Unexpected IPA size")
                data=z.read(member)
                files[key]=executable_digest(data) if key==i["CFBundleExecutable"] else digest(data)
    return files
def verify(signed,sha,udid,unsigned,revision,frozen):
    require(is_hash(sha) and sha_file(signed)==sha,"Signed IPA digest mismatch")
    subprocess.run(["python3",str(NATIVE/"Checks/inspect_ipa.py"),"--signed","--discovery","personal",str(signed)],check=True)
    i,p=info(signed);signed_rev=i.get(STAMP)
    require(signed_rev==revision or revision_fingerprint(signed_rev)==frozen,"Signed IPA revision is not the frozen review source")
    with zipfile.ZipFile(signed) as z:
        profile=profile_issued_by_apple(z.read(p+"embedded.mobileprovision"))
        for_device(profile,udid)
        binary=z.read(p+i["CFBundleExecutable"])
        personal_entitlements(executable_entitlements(binary),profile.get("Entitlements",{}))
        development_certificate(binary,profile)
    require(bundle_payload(unsigned)==bundle_payload(signed,signed=True),"Signed app payload differs from the independently inspected unsigned personal build")
    require(sha_file(signed)==sha,"Signed artifact changed during verification")
    print("Signed personal IPA: Apple-issued development profile, intended device, reviewed code/resources and complete file SHA-256 verified")
