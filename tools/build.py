"""Builds the mod's .pak from src/ and verifies it.

Checks that the version in BootstrapClient.lua matches meta.lsx, packs src/ into
an LSPK v13 package (the Divinity: Original Sin 2 Definitive Edition format), then
reads the package back and confirms every file round-trips byte for byte.

usage:
  python tools/build.py                    # dist/CenteredHUD.pak
  python tools/build.py --versioned        # dist/CenteredHUD-1.0.0.pak
  python tools/build.py --tag v1.0.0       # also fail unless the tag matches the version
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lspk  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(REPO_ROOT, "src")
MOD_NAME = "CenteredHUD"

# The game rejects add-ons whose PublishVersion predates the Definitive Edition
# ("Incompatible mod! A mod published using the Classic Edition..."). See FINDINGS.md.
MIN_PUBLISH_VERSION = 909321303  # 3.6.51.9303


def unpack_version(value):
    return (value >> 28, (value >> 24) & 0x0F, (value >> 16) & 0xFF, value & 0xFFFF)


def find_mod_dir():
    mods = [d for d in os.listdir(os.path.join(SRC_DIR, "Mods")) if d.startswith(MOD_NAME + "_")]
    if len(mods) != 1:
        sys.exit("expected exactly one src/Mods/%s_<uuid> folder, found %r" % (MOD_NAME, mods))
    return os.path.join(SRC_DIR, "Mods", mods[0])


def read_versions(mod_dir):
    meta = open(os.path.join(mod_dir, "meta.lsx"), encoding="utf-8").read()
    module_info = meta[meta.index('<node id="ModuleInfo">'):]
    version = int(re.search(r'<attribute id="Version" value="(\d+)"', module_info).group(1))
    publish = int(re.search(
        r'<node id="PublishVersion">\s*<attribute id="Version" value="(\d+)"', module_info).group(1))

    lua = open(os.path.join(mod_dir, "Story", "RawFiles", "Lua", "BootstrapClient.lua"), encoding="utf-8").read()
    lua_version = re.search(r'^local VERSION = "([^"]+)"', lua, re.M).group(1)
    return version, publish, lua_version


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default=os.path.join(REPO_ROOT, "dist"), help="output directory (default: dist/)")
    parser.add_argument("--versioned", action="store_true", help="include the version in the file name")
    parser.add_argument("--tag", help="git tag being released; must equal v<version>")
    args = parser.parse_args()

    mod_dir = find_mod_dir()
    version, publish, lua_version = read_versions(mod_dir)
    major, minor, revision, build = unpack_version(version)
    meta_version = "%d.%d.%d" % (major, minor, revision)

    errors = []
    if lua_version != meta_version:
        errors.append("BootstrapClient.lua VERSION is %s but meta.lsx Version is %s (%d)" % (lua_version, meta_version, version))
    if publish < MIN_PUBLISH_VERSION:
        errors.append("meta.lsx PublishVersion %d is below %d; the game would flag the mod as Classic Edition" % (publish, MIN_PUBLISH_VERSION))
    if args.tag and args.tag != "v" + meta_version:
        errors.append("tag %s does not match version v%s" % (args.tag, meta_version))
    if errors:
        sys.exit("build failed:\n  " + "\n  ".join(errors))

    os.makedirs(args.out, exist_ok=True)
    name = "%s-%s.pak" % (MOD_NAME, meta_version) if args.versioned else MOD_NAME + ".pak"
    pak_path = os.path.join(args.out, name)
    packed = lspk.pack(SRC_DIR, pak_path)

    # Round-trip: every packed file must decompress to its source bytes.
    _, entries = lspk.read_package(pak_path)
    if sorted(e["name"] for e in entries) != sorted(packed):
        sys.exit("build failed: package file list does not match src/")
    for entry in entries:
        with open(os.path.join(SRC_DIR, entry["name"]), "rb") as f:
            if lspk.read_entry(pak_path, entry) != f.read():
                sys.exit("build failed: %s does not round-trip" % entry["name"])

    print("built %s (v%s, %d files, %.1f KB)" % (os.path.relpath(pak_path, REPO_ROOT), meta_version, len(entries), os.path.getsize(pak_path) / 1024))


if __name__ == "__main__":
    main()
