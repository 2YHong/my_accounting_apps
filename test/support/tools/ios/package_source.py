"""Create a source-only handoff archive without build outputs or local credentials."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIRS = ("lib", "test", "assets", "ios", "tools", "docs")
ROOT_FILES = ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml",
              "codemagic.yaml", ".metadata", ".gitignore", "README.md")
BLOCKED_PARTS = {".git", ".dart_tool", ".idea", ".vscode", "build", "pods",
                 ".symlinks", "ephemeral", "xcuserdata", "deriveddata", "__pycache__",
                 "backups", "diagnostics", "pb_data"}
BLOCKED_SUFFIXES = {".p8", ".p12", ".pfx", ".pem", ".key", ".keystore", ".jks",
                    ".mobileprovision", ".db", ".sqlite", ".sqlite3", ".log",
                    ".ipa", ".apk", ".xcuserstate", ".pyc", ".accountingbackup", ".aab"}
BLOCKED_NAMES = {"cloud-config.json", "local.properties", "key.properties",
                 "generated.xcconfig", "flutter_export_environment.sh",
                 ".flutter-plugins-dependencies"}
TEXT_SUFFIXES = {".dart", ".json", ".yaml", ".md", ".py", ".cjs", ".swift", ".h", ".m",
                 ".plist", ".xcconfig", ".entitlements", ".xcprivacy", ".pbxproj", ".sh"}


def allowed(relative):
    parts = {part.lower() for part in relative.parts}
    name = relative.name.lower()
    return not (parts & BLOCKED_PARTS or relative.suffix.lower() in BLOCKED_SUFFIXES or
                name in BLOCKED_NAMES or name.startswith(".env") or
                name.startswith("generatedpluginregistrant") or name.endswith("-journal") or
                name.endswith("-wal") or name.endswith("-shm") or
                name.endswith(".ios-prepare.tmp"))


def collect(root):
    root = Path(root).resolve()
    result = []
    for name in ROOT_FILES:
        path = root / name
        if path.is_file():
            result.append(path)
    for name in SOURCE_DIRS:
        base = root / name
        if base.is_dir():
            for path in base.rglob("*"):
                relative = path.relative_to(root)
                if not allowed(relative):
                    continue
                if path.is_symlink():
                    raise ValueError("Source package must not follow symlinks: " + str(relative))
                if path.is_file():
                    result.append(path)
    result = sorted(set(result))
    for path in result:
        data = path.read_bytes()
        # Match a real PEM header line, not this check's own source string.
        if re.search(rb"(?m)^-----BEGIN (?:RSA )?PRIVATE KEY-----\r?$", data):
            raise ValueError("Private key material found in " + str(path.relative_to(root)))
    return result


def package(output, root=ROOT):
    root = Path(root).resolve()
    output = Path(output).resolve()
    if output == root or root in output.parents:
        raise ValueError("Save the handoff archive outside the application project")
    files = collect(root)
    rows = [{"path": path.relative_to(root).as_posix(),
             "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in files]
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation: a second run must not overwrite an existing handoff.
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in files:
            archive.write(path, path.relative_to(root).as_posix())
        archive.writestr("SOURCE_PACKAGE.json", json.dumps(
            {"format": "accounting.ios_source", "files": rows,
             "contains_personal_database": False, "contains_signing_credentials": False},
            ensure_ascii=False, indent=2))
    return {"archive": str(output), "source_files": len(files), "bytes": output.stat().st_size}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(package(args.output), ensure_ascii=False, indent=2))
