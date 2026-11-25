#!/usr/bin/env python3
"""Package a verified Cellar.app bundle into a drag-to-install DMG using dmgbuild 1.6.7."""

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from importlib.metadata import version
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_VERSION_RE = re.compile(r"^(\d+\.\d+\.\d+)")


def read_manifest():
    subprocess.run(["node", str(ROOT / ".github/scripts/sync-version.mjs"), "--check"], cwd=ROOT, check=True)
    return json.loads((ROOT / "Config/Release/manifest.json").read_text(encoding="utf-8"))


def output_path(output, manifest, release):
    build = ROOT / "build"
    if build.is_symlink():
        raise ValueError("Build directory must not redirect output outside this repository")
    if output is None:
        suffix = "" if release else "-" + str(manifest["build"]) + "-test"
        output = build / ("Cellar-" + manifest["version"] + suffix + ".dmg")
    else:
        output = Path(output)
        if not output.is_absolute():
            output = ROOT / output
    if ".." in output.parts:
        raise ValueError("DMG output must not contain parent-directory traversal")
    try:
        relative = output.relative_to(build)
    except ValueError as error:
        raise ValueError("DMG output must be inside this repository's build directory") from error
    if not relative.parts or output.suffix != ".dmg":
        raise ValueError("Output must be a .dmg file inside build")
    for path in (output, *output.parents):
        if path == ROOT:
            break
        if path.is_symlink():
            raise ValueError("DMG output must not use symbolic links: " + str(path))
    if output.exists():
        raise ValueError("Refusing to overwrite existing DMG: " + str(output))
    return output


def package(app, output=None, release=False):
    manifest = read_manifest()
    if not manifest["packagingEnabled"]:
        raise ValueError("Packaging is disabled in Config/Release/manifest.json")
    app = Path(app).resolve()
    if not app.is_dir() or app.name != "Cellar.app":
        raise ValueError("Input must be the Cellar.app bundle")
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    base_match = BASE_VERSION_RE.match(manifest["version"])
    if not base_match:
        raise ValueError("Invalid version in Config/Release/manifest.json")
    expected = {
        "CFBundleIdentifier": "com.dylanwang.Cellar",
        "CFBundleShortVersionString": base_match.group(1),
        "CFBundleVersion": str(manifest["build"]),
        "LSMinimumSystemVersion": "26.0",
    }
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("App identity, minimum macOS, or version does not match the release manifest")
    flag = info.get("CellarUpdaterEnabled")
    enabled = flag is True or flag == "YES"
    disabled = flag is False or flag == "NO"
    if (release and not enabled) or (not release and not disabled):
        raise ValueError("CellarUpdaterEnabled must be YES/true for releases and NO/false for test packages")
    output = output_path(output, manifest, release)
    if sys.platform != "darwin" or sys.version_info < (3, 10):
        raise ValueError("DMG packaging requires macOS and Python 3.10+")
    if version("dmgbuild") != "1.6.7":
        raise ValueError("Install dmgbuild==1.6.7 in the packaging environment")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Build privately, then publish with a no-replace hard link.
    with tempfile.TemporaryDirectory(prefix="dmg-", dir=output.parent) as staging:
        image = Path(staging) / output.name
        subprocess.run(
            [
                sys.executable,
                "-m",
                "dmgbuild",
                "-s",
                str(ROOT / "Config/DMG/settings.py"),
                "-D",
                "app=" + str(app),
                f"Cellar {manifest['version']}",
                str(image),
            ],
            check=True,
        )
        os.link(image, output)
    return output


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--output", type=Path, default=None, help="Output DMG path inside build/")
    parser.add_argument("--release", action="store_true", help="Require the signed-feed updater to be enabled")
    args = parser.parse_args()
    try:
        print(package(args.app, args.output, args.release))
    except (ValueError, OSError, ImportError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")
