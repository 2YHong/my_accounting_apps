"""Manual Codemagic build stages. All Apple credentials stay in the CI environment."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

from prepare import ROOT, prepare
from validate import validate

CONFIG = json.loads((ROOT / "tools/ios/build_config.json").read_text(encoding="utf-8"))
# This iOS release follows the basic Android edition, including if a CI flavor is set.
BASIC_BUILD_FLAGS = ("--dart-define=ACCOUNTING_DISABLE_SCREENSHOT=true",)
SECRET_NAMES = ("APP_STORE_CONNECT_ISSUER_ID", "APP_STORE_CONNECT_KEY_IDENTIFIER",
                "APP_STORE_CONNECT_PRIVATE_KEY", "CERTIFICATE_PRIVATE_KEY")


def run(*command, cwd=ROOT):
    # Commands never contain private key material. Do not print the environment.
    print("+ " + " ".join(str(item) for item in command), flush=True)
    subprocess.run([str(item) for item in command], cwd=cwd, check=True)


def require_credentials():
    missing = [name for name in SECRET_NAMES if not os.environ.get(name, "").strip()]
    if missing:
        raise ValueError("Add these secret variables to appstore_credentials: " + ", ".join(missing))
    for name in SECRET_NAMES[2:]:
        if "PRIVATE KEY-----" not in os.environ[name]:
            raise ValueError(name + " must contain the complete PEM private key")
    return {"credentials_present": True}


def build_number():
    # Codemagic increments this counter per project, including retried builds.
    # Encode it within Apple's 4/2/2 digit CFBundleVersion component limits.
    counter = int(os.environ.get("PROJECT_BUILD_NUMBER") or
                  os.environ.get("BUILD_NUMBER") or "1")
    if not 0 <= counter < 99990000:
        raise ValueError("Cloud build counter is outside the supported range")
    return f"{counter // 10000 + 1}.{(counter // 100) % 100}.{counter % 100}"


def prepare_stage():
    result = prepare(official_pub=True)
    if os.environ.get("CM_ENV"):
        with open(os.environ["CM_ENV"], "a", encoding="utf-8") as stream:
            stream.write("IOS_BUNDLE_ID=" + result["bundle_identifier"] + "\n")
    # CocoaPods is intentionally used for these pinned plugin versions.
    run("flutter", "config", "--no-enable-swift-package-manager")
    run("flutter", "pub", "get", "--enforce-lockfile")
    report = validate()
    destination = ROOT / "build/ios/diagnostics"
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "preflight.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    run("pod", "install", "--repo-update", cwd=ROOT / "ios")


def checks():
    # Existing lint warnings are retained; compilation errors still stop CI.
    run("flutter", "analyze", "--no-pub", "--no-fatal-infos", "--no-fatal-warnings")
    run("flutter", "test", "--no-pub", "--concurrency=1", "--reporter", "expanded",
        *BASIC_BUILD_FLAGS)


def package_unsigned_ipa(app, destination):
    """Package a compiled iPhone app for later re-signing, never a simulator app."""
    app = Path(app).resolve()
    destination = Path(destination).resolve()
    if app.suffix != ".app" or destination.suffix != ".ipa":
        raise ValueError("Expected a compiled .app bundle and an .ipa output path")
    info_path = app / "Info.plist"
    if not info_path.is_file():
        raise ValueError("Compile the iPhone app before packaging an IPA")
    info = plistlib.loads(info_path.read_bytes())
    if (info.get("DTPlatformName") != "iphoneos" or
            "iPhoneOS" not in info.get("CFBundleSupportedPlatforms", [])):
        raise ValueError("Only an iPhoneOS build can become this IPA; simulator builds are rejected")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable:
        raise ValueError("The compiled app has no valid bundle executable")
    binary = app / executable
    if not binary.is_file():
        raise ValueError("The compiled bundle executable is missing")
    with binary.open("rb") as stream:
        magic = stream.read(4)
    # Mach-O / universal binary headers, not Dart source, an APK, or a source ZIP.
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
                     b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                     b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
        raise ValueError("The bundle executable is not a compiled Mach-O binary")
    if destination.exists():
        raise FileExistsError("Refusing to replace an existing IPA: " + str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = tempfile.TemporaryDirectory(prefix=".ipa-package-", dir=destination.parent)
    stage = Path(temporary.name).resolve()
    if destination.parent not in stage.parents:
        raise ValueError("IPA staging directory escaped its output folder")
    try:
        payload = stage / "Payload"
        payload.mkdir()
        # macOS ditto preserves framework symlinks and executable permissions.
        run("ditto", app, payload / app.name)
        packed = stage / "unsigned.ipa"
        run("ditto", "-c", "-k", "--keepParent", payload, packed)
        with zipfile.ZipFile(packed) as archive:
            expected = {"Payload/" + app.name + "/Info.plist",
                        "Payload/" + app.name + "/" + executable}
            if not expected.issubset(archive.namelist()):
                raise ValueError("IPA packaging did not preserve the Payload/app layout")
        # Both resolved targets are inside the explicitly selected output folder.
        packed.rename(destination)
    finally:
        temporary.cleanup()
    return destination


def unsigned():
    version = build_number()
    run("flutter", "build", "ios", "--release", "--no-codesign",
        "--no-tree-shake-icons", "--no-pub", "--build-number=" + version,
        *BASIC_BUILD_FLAGS)
    output = ROOT / "build/ios/artifacts"
    output.mkdir(parents=True, exist_ok=True)
    # Save the physical-device app before the simulator build reuses outputs.
    package_unsigned_ipa(ROOT / "build/ios/iphoneos/Runner.app",
                         output / "my-accounting-app-unsigned.ipa")
    run("flutter", "build", "ios", "--simulator", "--debug", "--no-codesign",
        "--no-tree-shake-icons", "--no-pub", "--build-number=" + version,
        *BASIC_BUILD_FLAGS)
    run("ditto", "-c", "-k", "--keepParent", ROOT / "build/ios/iphonesimulator/Runner.app",
        output / "SIMULATOR-only-not-for-iphone.zip")
    print("Unsigned iPhone IPA created; it must be signed before installation.")
    print("The simulator ZIP cannot run on a physical iPhone.")


def signed():
    require_credentials()
    validate()
    run("keychain", "initialize")
    try:
        run("app-store-connect", "fetch-signing-files",
            os.environ.get("IOS_BUNDLE_ID") or CONFIG["bundle_identifier"],
            "--platform", "IOS", "--type", "IOS_APP_STORE", "--create")
        run("keychain", "add-certificates")
        run("xcode-project", "use-profiles")
        export = Path.home() / "export_options.plist"
        if not export.is_file():
            raise ValueError("xcode-project did not create export_options.plist")
        run("flutter", "build", "ipa", "--release", "--no-tree-shake-icons", "--no-pub",
            "--build-number=" + build_number(), "--export-options-plist=" + str(export),
            *BASIC_BUILD_FLAGS)
    finally:
        # Match Codemagic/Flutter guidance: restore the builder's login keychain.
        run("keychain", "use-login")
    print("Signed IPA created. This workflow does not upload it or invite testers.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=("prepare", "checks", "unsigned", "credentials", "signed"))
    args = parser.parse_args()
    if platform.system() != "Darwin":
        raise ValueError("Run this command on a Codemagic macOS worker, not Windows.")
    {"prepare": prepare_stage, "checks": checks, "unsigned": unsigned,
     "credentials": require_credentials, "signed": signed}[args.stage]()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
