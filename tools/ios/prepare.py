"""Configure only this iOS project; no network, signing, or business data access."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[2]


def prepare(root=ROOT, bundle_id=None, official_pub=False):
    root = Path(root).resolve()
    config = json.loads((root / "tools/ios/build_config.json").read_text(encoding="utf-8"))
    bundle_id = bundle_id or os.environ.get("IOS_BUNDLE_ID") or config["bundle_identifier"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*){2,}", bundle_id):
        raise ValueError("IOS_BUNDLE_ID must contain at least three reverse-DNS components")
    if bundle_id.lower().startswith("com.example."):
        raise ValueError("Replace the example bundle identifier before building")
    project = root / "ios/Runner.xcodeproj/project.pbxproj"
    pbx = project.read_text(encoding="utf-8")
    pattern = r"PRODUCT_BUNDLE_IDENTIFIER = ([A-Za-z0-9.-]+);"
    if len(re.findall(pattern, pbx)) != 6:
        raise ValueError("Unexpected Xcode target layout; refusing to partially configure it")

    def replacement(match):
        suffix = ".RunnerTests" if match.group(1).endswith(".RunnerTests") else ""
        return "PRODUCT_BUNDLE_IDENTIFIER = " + bundle_id + suffix + ";"

    pbx = re.sub(pattern, replacement, pbx)
    info_path = root / "ios/Runner/Info.plist"
    with info_path.open("rb") as stream:
        info = plistlib.load(stream)
    info["CFBundleDisplayName"] = config["display_name"]
    info["CFBundleLocalizations"] = ["zh-Hans"]
    info["LSSupportsOpeningDocumentsInPlace"] = True
    # The app implements its own encryption. Exemption declarations require a
    # separate App Store Connect determination; never silently set them false.
    updates = {project: pbx.encode("utf-8"),
               info_path: plistlib.dumps(info, sort_keys=False)}
    if official_pub:
        lock = root / "pubspec.lock"
        text = lock.read_text(encoding="utf-8")
        updates[lock] = text.replace("https://pub.flutter-io.cn", "https://pub.dev").encode("utf-8")
    for path, data in updates.items():
        if path.read_bytes() != data:
            temporary = path.with_name(path.name + ".ios-prepare.tmp")
            temporary.write_bytes(data)
            temporary.replace(path)
    return {"bundle_identifier": bundle_id, "display_name": config["display_name"],
            "minimum_ios": config["minimum_ios"], "registry_normalized": official_pub}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle-id")
    parser.add_argument("--official-pub", action="store_true",
                        help="CI only: use the official registry, keeping versions and checksums")
    args = parser.parse_args()
    print(json.dumps(prepare(bundle_id=args.bundle_id, official_pub=args.official_pub),
                     ensure_ascii=False))
