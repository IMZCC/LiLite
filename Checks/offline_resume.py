"""Compile the production checkpoint, permission and history policies. --live adds an anonymous read."""
from pathlib import Path
import sys, subprocess,tempfile
native=Path(__file__).resolve().parents[1]
sources=native/"Sources/PiliNative"
with tempfile.TemporaryDirectory() as tmp:
    work=Path(tmp)
    # Reuse the project's anonymous GET helper and actual WebQuery signer; do not persist signed URLs.
    public=(native/"Checks/PublicServiceCheck.swift").read_text()
    prefix=public.split("  static func main() async {",1)[0].replace("@main enum PublicServiceCheck","enum PublicProbe")
    prefix="\n".join(x for x in prefix.splitlines() if "struct VideoList: Decodable" not in x and "struct SeriesList: Decodable" not in x)
    probe=work/"PublicProbe.swift";probe.write_text(prefix+"\n}\n")
    deps=["Network/ServiceError","Network/ArchiveNumber","Network/WebQuery","Library/FolderAccessIO","Offline/OfflinePackage","Offline/OfflineIndexStore","Offline/LegacyCacheCatalog","Offline/OfflineShelfFilter","Offline/OfflineVideo","Offline/OfflinePieces","Offline/OfflineWatchBook","Offline/ArchiveCachePolicy","Playback/RelayRange","Playback/MediaRange","Playback/EpisodeClips","Decoder/AudioFilterChoice"]
    deps.append("Offline/LegacyMediaComponents")
    subprocess.run(["swiftc",*[str(sources/(f+".swift")) for f in deps],str(probe),str(native/"Checks/OfflineResumeCheck.swift"),"-lcrypto","-o",str(work/"check")],check=True)
    sys.exit(subprocess.run([str(work/"check"),*sys.argv[1:]]).returncode)
