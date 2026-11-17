"""Use Bonjour + directed DLNA/IP discovery for personal teams, without the multicast entitlement."""
import plistlib, sys
from pathlib import Path

def configure(staging):
    ent=staging/"Resources/PiliPlus.entitlements"
    info=staging/"Resources/Info.plist"
    e=plistlib.loads(ent.read_bytes());p=plistlib.loads(info.read_bytes())
    if e.pop("com.apple.developer.networking.multicast",None) is not True or p.get("PiliMulticastDiscovery") is not True:
        raise ValueError("Expected the full multicast staging configuration")
    p["PiliMulticastDiscovery"]=False
    ent.write_bytes(plistlib.dumps(e))
    info.write_bytes(plistlib.dumps(p))

if __name__=="__main__": configure(Path(sys.argv[1]))
