import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest import mock
import zipfile

import ci
from package_source import package
from prepare import ROOT, prepare
from validate import validate


class IosPreparationTests(unittest.TestCase):
    def setUp(self):
        base = Path(os.environ.get("ACCOUNTING_IOS_TEST_TMP", tempfile.gettempdir())).resolve()
        base.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="accounting-ios-test-", dir=base)
        self.folder = Path(self.temporary.name).resolve()
        if base not in self.folder.parents:
            raise ValueError("Test temporary folder escaped its configured root")
        self.addCleanup(self.temporary.cleanup)
        self.root = self.folder / "project"
        self.root.mkdir()

    def fixture(self):
        shutil.copytree(ROOT / "ios", self.root / "ios",
                        ignore=shutil.ignore_patterns("Pods", ".symlinks", "ephemeral", "xcuserdata"))
        (self.root / "tools/ios").mkdir(parents=True)
        shutil.copy(ROOT / "tools/ios/build_config.json", self.root / "tools/ios/build_config.json")
        for name in ("codemagic.yaml", "pubspec.lock", "pubspec.yaml"):
            shutil.copy(ROOT / name, self.root / name)
        return self.root

    def test_reconfiguration_preserves_native_config_and_is_idempotent(self):
        root = self.fixture()
        prepare(root, bundle_id="com.testing.accounting")
        result = validate(root)
        self.assertEqual(result["bundle_identifier"], "com.testing.accounting")
        before = {p: p.read_bytes() for p in (root / "ios").rglob("*") if p.is_file()}
        prepare(root, bundle_id="com.testing.accounting")
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_invalid_bundle_id_leaves_project_unchanged(self):
        root = self.fixture()
        original = (root / "ios/Runner.xcodeproj/project.pbxproj").read_bytes()
        for invalid in ("com.example.app", "com.app\nOTHER=value", "../bad", "com.single"):
            with self.assertRaises(ValueError):
                prepare(root, bundle_id=invalid)
        self.assertEqual(original, (root / "ios/Runner.xcodeproj/project.pbxproj").read_bytes())

    def test_registry_normalization_keeps_exact_versions_and_hashes(self):
        root = self.fixture()
        old = (root / "pubspec.lock").read_text(encoding="utf-8")
        prepare(root, official_pub=True)
        new = (root / "pubspec.lock").read_text(encoding="utf-8")
        self.assertEqual(new, old.replace("https://pub.flutter-io.cn", "https://pub.dev"))

    def test_manifest_must_be_linked_in_native_resources(self):
        root = self.fixture()
        path = root / "ios/Runner.xcodeproj/project.pbxproj"
        path.write_text(path.read_text(encoding="utf-8").replace(
            "PrivacyInfo.xcprivacy in Resources", "Unlinked manifest"), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "manifest"):
            validate(root)

    def test_unreviewed_encryption_and_insecure_transport_are_rejected(self):
        root = self.fixture()
        path = root / "ios/Runner/Info.plist"
        original = plistlib.loads(path.read_bytes())
        for value in (
            {**original, "ITSAppUsesNonExemptEncryption": False},
            {**original, "NSAppTransportSecurity": {"NSAllowsArbitraryLoads": True}},
        ):
            path.write_bytes(plistlib.dumps(value))
            with self.assertRaises(ValueError):
                validate(root)

    def test_source_archive_excludes_personal_data_builds_and_keys(self):
        data = {
            "pubspec.yaml": "name: example",
            "lib/main.dart": "void main() {}",
            "assets/voice/model.onnx": "test-model",
            "ios/Runner/Info.plist": "public",
            "tools/ios/tool.py": "print('public')",
            "ios/Flutter/Generated.xcconfig": "personal-machine",
            "ios/.symlinks/plugins/private.txt": "generated",
            "ios/Pods/native/private.txt": "generated",
            "lib/accidental.db": "personal",
            "tools/key.p8": "private",
            "tools/distribution.PEM": "private",
            "tools/.env.production": "private",
            "build/private.ipa": "private",
            "cloud-config.json": "private",
        }
        for relative, value in data.items():
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")
        output = self.folder / "source.zip"
        result = package(output, self.root)
        self.assertEqual(result["source_files"], 5)
        with zipfile.ZipFile(output) as archive:
            names = set(archive.namelist())
            self.assertEqual(names, {"pubspec.yaml", "lib/main.dart", "assets/voice/model.onnx",
                "ios/Runner/Info.plist", "tools/ios/tool.py", "SOURCE_PACKAGE.json"})
            manifest = json.loads(archive.read("SOURCE_PACKAGE.json"))
            for row in manifest["files"]:
                self.assertEqual(row["sha256"], hashlib.sha256(archive.read(row["path"])).hexdigest())
        with self.assertRaises(FileExistsError):
            package(output, self.root)
        with self.assertRaises(ValueError):
            package(self.root / "source.zip", self.root)

    def test_pasted_private_key_is_rejected_even_with_unrecognized_extension(self):
        path = self.root / "lib/accidental.inc"
        path.parent.mkdir()
        path.write_text("-----BEGIN PRIVATE KEY-----\nsynthetic-test-data\n-----END PRIVATE KEY-----\n",
                        encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "Private key"):
            package(self.folder / "source.zip", self.root)
        self.assertFalse((self.folder / "source.zip").exists())

    def test_signing_needs_all_credentials_and_build_numbers_obey_apple_limits(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(ValueError, "APP_STORE_CONNECT_ISSUER_ID"):
                ci.require_credentials()
            for count in (0, 1, 99, 100, 9999, 10000, 99989999):
                os.environ["PROJECT_BUILD_NUMBER"] = str(count)
                parts = ci.build_number().split(".")
                self.assertTrue(1 <= int(parts[0]) <= 9999)
                self.assertTrue(all(0 <= int(part) <= 99 for part in parts[1:]))
                self.assertEqual(int(parts[0]) * 10000 + int(parts[1]) * 100 + int(parts[2]),
                                 count + 10000)

    def test_signing_restores_keychain_and_does_not_publish(self):
        commands = []
        def fake_run(*args, **kwargs):
            commands.append(args)
            if args[0] == "flutter":
                raise RuntimeError("simulated compiler failure")
        (self.folder / "export_options.plist").write_text("test", encoding="utf-8")
        with mock.patch.object(ci, "run", side_effect=fake_run), \
             mock.patch.object(ci, "require_credentials"), \
             mock.patch.object(ci, "validate"), \
             mock.patch.object(ci.Path, "home", return_value=self.folder):
            with self.assertRaises(RuntimeError):
                ci.signed()
        self.assertEqual(commands[-1], ("keychain", "use-login"))
        self.assertFalse(any("publish" in command for command in commands))


    def test_non_basic_configuration_and_ocr_native_dependency_are_rejected(self):
        root = self.fixture()
        path = root / "tools/ios/build_config.json"
        config = json.loads(path.read_text(encoding="utf-8"))
        config["edition"] = "screenshot"
        path.write_text(json.dumps(config), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "basic edition"):
            validate(root)
        config["edition"] = "basic"
        path.write_text(json.dumps(config), encoding="utf-8")
        podfile = root / "ios/Podfile"
        with podfile.open("a", encoding="utf-8") as stream:
            stream.write("\npod 'GoogleMLKit/TextRecognitionChinese'\n")
        with self.assertRaisesRegex(ValueError, "OCR native"):
            validate(root)

    def test_all_unsigned_device_and_simulator_builds_disable_screenshot(self):
        commands = []
        with mock.patch.object(ci, "ROOT", self.root), \
             mock.patch.object(ci, "package_unsigned_ipa"), \
             mock.patch.object(ci, "run", side_effect=lambda *args, **kw: commands.append(args)):
            ci.unsigned()
        builds = [row for row in commands if row[:2] == ("flutter", "build")]
        self.assertEqual(len(builds), 2)
        for command in builds:
            self.assertIn("--dart-define=ACCOUNTING_DISABLE_SCREENSHOT=true", command)
            self.assertNotIn("--flavor", command)
            self.assertNotIn("screenshot", command)

    def test_signed_build_uses_the_same_basic_configuration(self):
        commands = []
        (self.folder / "export_options.plist").write_text("test", encoding="utf-8")
        with mock.patch.object(ci, "run", side_effect=lambda *args, **kw: commands.append(args)), \
             mock.patch.object(ci, "require_credentials"), \
             mock.patch.object(ci, "validate"), \
             mock.patch.object(ci.Path, "home", return_value=self.folder):
            ci.signed()
        builds = [row for row in commands if row[:3] == ("flutter", "build", "ipa")]
        self.assertEqual(len(builds), 1)
        self.assertIn("--dart-define=ACCOUNTING_DISABLE_SCREENSHOT=true", builds[0])
        self.assertEqual(commands[-1], ("keychain", "use-login"))
        self.assertFalse(any("publish" in str(row) for row in commands))

    def compiled_app(self, platform="iphoneos"):
        app = self.root / "Runner.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "Runner",
            "DTPlatformName": platform,
            "CFBundleSupportedPlatforms": [
                "iPhoneOS" if platform == "iphoneos" else "iPhoneSimulator"],
        }))
        (app / "Runner").write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic-compiled-fixture")
        framework = app / "Frameworks/Example.framework"
        framework.mkdir(parents=True)
        (framework / "Example").write_bytes(b"native-framework-fixture")
        (app / "assets").mkdir()
        (app / "assets/model.onnx").write_bytes(b"model-fixture")
        return app

    def test_unsigned_ipa_contains_compiled_app_frameworks_and_assets(self):
        app = self.compiled_app()
        output = self.folder / "artifacts/test-unsigned.ipa"
        def fake_ditto(*args, **kwargs):
            self.assertEqual(args[0], "ditto")
            if args[1:4] == ("-c", "-k", "--keepParent"):
                source, target = Path(args[4]), Path(args[5])
                with zipfile.ZipFile(target, "w") as archive:
                    for path in source.rglob("*"):
                        if path.is_file():
                            archive.write(path, path.relative_to(source.parent).as_posix())
            else:
                shutil.copytree(args[1], args[2], symlinks=True)
        with mock.patch.object(ci, "run", side_effect=fake_ditto):
            ci.package_unsigned_ipa(app, output)
            with self.assertRaises(FileExistsError):
                ci.package_unsigned_ipa(app, output)
        with zipfile.ZipFile(output) as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(set(archive.namelist()), {
                "Payload/Runner.app/Info.plist",
                "Payload/Runner.app/Runner",
                "Payload/Runner.app/Frameworks/Example.framework/Example",
                "Payload/Runner.app/assets/model.onnx"})
        self.assertEqual(list(output.parent.glob(".ipa-package-*")), [])

    def test_unsigned_ipa_rejects_simulator_and_uncompiled_source(self):
        app = self.compiled_app(platform="iphonesimulator")
        output = self.folder / "wrong.ipa"
        with mock.patch.object(ci, "run") as command:
            with self.assertRaisesRegex(ValueError, "simulator"):
                ci.package_unsigned_ipa(app, output)
            info = plistlib.loads((app / "Info.plist").read_bytes())
            info.update(DTPlatformName="iphoneos", CFBundleSupportedPlatforms=["iPhoneOS"])
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "Runner").write_bytes(b"this-is-source-not-a-native-executable")
            with self.assertRaisesRegex(ValueError, "Mach-O"):
                ci.package_unsigned_ipa(app, output)
            command.assert_not_called()
        self.assertFalse(output.exists())

    def test_unsigned_saves_physical_ipa_before_building_simulator(self):
        commands = []
        with mock.patch.object(ci, "ROOT", self.root), \
             mock.patch.object(ci, "build_number", return_value="1.0.1"), \
             mock.patch.object(ci, "package_unsigned_ipa") as pack:
            def fake_run(*args, **kwargs):
                commands.append(args)
                if "--simulator" in args:
                    pack.assert_called_once_with(
                        self.root / "build/ios/iphoneos/Runner.app",
                        self.root / "build/ios/artifacts/my-accounting-app-unsigned.ipa")
            with mock.patch.object(ci, "run", side_effect=fake_run):
                ci.unsigned()
        self.assertEqual(commands[0][:5], ("flutter", "build", "ios", "--release", "--no-codesign"))
        self.assertFalse(any("signing" in str(command) for command in commands))


if __name__ == "__main__":
    unittest.main()
