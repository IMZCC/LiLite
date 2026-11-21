"""Stage Firebase's official static iOS frameworks and their resources for the Xcode build.

Writes <root>/FirebaseSDK (gitignored): iphoneos/ and iphonesimulator/ framework slices,
xcframeworks/ (both slices, linked by Package.swift as binary targets), and the resources the
app target's "Embed Firebase resources" phase copies into the bundle.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from zipfile import ZipFile

VERSION = "13.2.0"
SHA256 = "528356de371830b3bbd0c32dbb649c080c8d36a6ef3d057590739eff6deaefcb"
PRODUCTS = {
    "FirebaseAnalytics": (
        "FirebaseAnalytics", "GoogleAppMeasurement", "FirebaseCore", "FirebaseCoreInternal",
        "FirebaseInstallations", "GoogleUtilities", "FBLPromises", "nanopb",
    ),
    "FirebaseCrashlytics": (
        "FirebaseCrashlytics", "FirebaseSessions", "FirebaseCoreExtension",
        "GoogleDataTransport", "FirebaseRemoteConfigInterop",
    ),
}
# Xcode $(PLATFORM_NAME) -> slice in the official xcframeworks. The app target embeds the
# resource bundles from FirebaseSDK/$(PLATFORM_NAME); Package.swift links FirebaseSDK/xcframeworks.
SLICES = {"iphoneos": "ios-arm64", "iphonesimulator": "ios-arm64_x86_64-simulator"}


def sha256(path):
    # hashlib.file_digest needs Python 3.11; Xcode ships 3.9.
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verified_archive():
    cache = Path.home() / ".cache/lilite-firebase"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"Firebase-{VERSION}.zip"
    if archive.exists() and sha256(archive) == SHA256:
        return archive
    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
        temp = Path(stream.name)
    try:
        url = f"https://github.com/firebase/firebase-ios-sdk/releases/download/{VERSION}/Firebase.zip"
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(temp), url], check=True)
        if sha256(temp) != SHA256:
            raise ValueError("Firebase SDK checksum mismatch")
        temp.replace(archive)
    finally:
        temp.unlink(missing_ok=True)
    return archive


def stage(root):
    dest = root / "FirebaseSDK"
    dest.mkdir(exist_ok=True)
    for stale in dest.glob("*.framework"):  # pre-simulator flat layout
        shutil.rmtree(stale)
    with ZipFile(verified_archive()) as sdk:
        items = [item for item in sdk.infolist() if not item.is_dir()]
        for platform, slice_name in SLICES.items():
            for product, names in PRODUCTS.items():
                for name in names:
                    prefix = f"Firebase/{product}/{name}.xcframework/{slice_name}/"
                    framework = dest / platform / f"{name}.framework"
                    for item in items:
                        if not item.filename.startswith(prefix):
                            continue
                        path = dest / platform / item.filename[len(prefix):]
                        path.parent.mkdir(parents=True, exist_ok=True)
                        # Preserve mtimes for unchanged headers between incremental builds.
                        data = sdk.read(item)
                        if not path.exists() or path.read_bytes() != data:
                            path.write_bytes(data)
                    if not (framework / name).is_file():
                        raise ValueError(f"Missing Firebase {platform} framework: {name}")
        # Repack each framework's static archive as an iOS-only (device + simulator) *library*
        # XCFramework for Package.swift. Framework-type xcframeworks would be embedded into the
        # app by Xcode although these binaries are static; headers come from -F iphoneos instead.
        packed = dest / "xcframeworks"
        stamp = packed / ".firebase-version"
        layout = VERSION + " static-library"
        if not stamp.is_file() or stamp.read_text() != layout:
            shutil.rmtree(packed, ignore_errors=True)
            packed.mkdir()
            for names in PRODUCTS.values():
                for name in names:
                    command = ["xcodebuild", "-create-xcframework"]
                    for platform in SLICES:
                        archive = packed / "libs" / platform / f"lib{name}.a"
                        archive.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(dest / platform / f"{name}.framework" / name, archive)
                        command += ["-library", str(archive)]
                    command += ["-output", str(packed / f"{name}.xcframework")]
                    subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            shutil.rmtree(packed / "libs")
            stamp.write_text(layout)
        notices = dest / "Firebase-NOTICES.txt"
        data = sdk.read("Firebase/NOTICES")
        if not notices.exists() or notices.read_bytes() != data:
            notices.write_bytes(data)
    config = Path(os.environ.get("LILITE_FIREBASE_PLIST", root / "Resources/GoogleService-Info.plist"))
    with config.open("rb") as stream:
        values = plistlib.load(stream)
    if values.get("BUNDLE_ID") != "com.liuliuya.PiliNative" or not all(
        values.get(key) for key in ("GOOGLE_APP_ID", "PROJECT_ID", "GCM_SENDER_ID", "API_KEY")
    ):
        raise ValueError("Expected the Firebase Apple configuration for com.liuliuya.PiliNative")
    staged = dest / "GoogleService-Info.plist"
    if not staged.exists() or staged.read_bytes() != config.read_bytes():
        shutil.copyfile(config, staged)
    print(dest)


if __name__ == "__main__":
    stage(Path(sys.argv[1]).resolve())
