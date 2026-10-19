"""Cross-platform source checks, not a substitute for Xcode or device testing."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import struct

ROOT = Path(__file__).resolve().parents[2]


def validate(root=ROOT):
    root = Path(root)
    config = json.loads((root / "tools/ios/build_config.json").read_text(encoding="utf-8"))
    if config.get("edition") != "basic" or config.get("screenshot_recognition") is not False:
        raise ValueError("This iOS release must use the basic edition without screenshot OCR")
    with (root / "ios/Runner/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    with (root / "ios/Runner/Runner.entitlements").open("rb") as stream:
        entitlements = plistlib.load(stream)
    with (root / "ios/Runner/PrivacyInfo.xcprivacy").open("rb") as stream:
        privacy = plistlib.load(stream)
    pbx = (root / "ios/Runner.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
    identifiers = re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.-]+);", pbx)
    app_ids = {value.removesuffix(".RunnerTests") for value in identifiers}
    if len(identifiers) != 6 or len(app_ids) != 1:
        raise ValueError("App and test bundle identifiers disagree")
    bundle_id = next(iter(app_ids))
    if not info.get("NSMicrophoneUsageDescription", "").strip():
        raise ValueError("The microphone purpose string is missing")
    if info["CFBundleDisplayName"] != config["display_name"]:
        raise ValueError("Display name differs from build_config.json")
    if info.get("NSAppTransportSecurity", {}).get("NSAllowsArbitraryLoads"):
        raise ValueError("Global insecure HTTP access must remain disabled")
    if "ITSAppUsesNonExemptEncryption" in info:
        raise ValueError("Encryption declarations need an explicit separate review")
    if entitlements.get("keychain-access-groups") != ["$(AppIdentifierPrefix)$(CFBundleIdentifier)"]:
        raise ValueError("Keep the device keychain scoped to this signed app")
    if privacy.get("NSPrivacyTracking") is not False:
        raise ValueError("Tracking declaration changed; review it before publishing")
    if "PrivacyInfo.xcprivacy in Resources" not in pbx:
        raise ValueError("The privacy manifest is not linked into the app")
    accessed = {item["NSPrivacyAccessedAPIType"]: set(item["NSPrivacyAccessedAPITypeReasons"])
                for item in privacy["NSPrivacyAccessedAPITypes"]}
    if not {"C617.1", "3B52.1"} <= accessed.get("NSPrivacyAccessedAPICategoryFileTimestamp", set()):
        raise ValueError("File metadata access reasons are missing")
    if "CA92.1" not in accessed.get("NSPrivacyAccessedAPICategoryUserDefaults", set()):
        raise ValueError("App preferences access reason is missing")
    for mode in ("Debug", "Release", "Profile"):
        text = (root / f"ios/Flutter/{mode}.xcconfig").read_text(encoding="utf-8")
        if f"Pods-Runner.{mode.lower()}.xcconfig" not in text or "Generated.xcconfig" not in text:
            raise ValueError(mode + " is missing a Flutter/CocoaPods include")
    with (root / "ios/Flutter/AppFrameworkInfo.plist").open("rb") as stream:
        framework = plistlib.load(stream)
    if framework.get("MinimumOSVersion") != config["minimum_ios"]:
        raise ValueError("Flutter app framework deployment target differs from Xcode")
    podfile = (root / "ios/Podfile").read_text(encoding="utf-8")
    if re.search(r"MLKit|GoogleMLKit|TextRecognition|ScreenshotBridge", podfile + pbx, re.I):
        raise ValueError("Screenshot OCR native dependencies are not part of the basic iOS edition")
    if "platform :ios, '" + config["minimum_ios"] + "'" not in podfile:
        raise ValueError("Minimum iOS version differs between configs")
    if set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);", pbx)) != {config["minimum_ios"]}:
        raise ValueError("Xcode deployment target differs from Podfile")
    manifest = json.loads((root / "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json")
                          .read_text(encoding="utf-8"))
    for image in manifest["images"]:
        filename = image.get("filename")
        if not filename:
            raise ValueError("An iOS app icon is missing")
        path = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset" / filename
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError("An app icon is not a PNG")
        width, height = struct.unpack(">II", data[16:24])
        points = float(image["size"].split("x")[0])
        expected = round(points * float(image["scale"].removesuffix("x")))
        if width != expected or height != expected:
            raise ValueError("Unexpected icon dimensions: " + filename)
    workflow = (root / "codemagic.yaml").read_text(encoding="utf-8")
    if "flutter: " + config["flutter_version"] not in workflow:
        raise ValueError("Cloud Flutter version does not match the local SDK")
    if 'xcode: "' + config["xcode_version"] + '"' not in workflow:
        raise ValueError("Cloud Xcode version differs from build_config.json")
    return {"source_checks": "passed", "bundle_identifier": bundle_id,
            "edition": "basic", "screenshot_recognition": False,
            "minimum_ios": config["minimum_ios"], "flutter": config["flutter_version"],
            "xcode": config["xcode_version"], "native_build_verified": False,
            "physical_device_verified": False, "icon_files": len(manifest["images"])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args()
    print(json.dumps(validate(args.root), ensure_ascii=False, indent=2))
