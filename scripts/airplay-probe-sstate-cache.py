#!/usr/bin/env python3
"""Bounded GitHub Actions persistence for completed Yocto sstate objects."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request

GENERATION_LIMIT = 4 * 1024**3
# Leave room for the outer Actions cache archive and its manifest.
LIMIT = GENERATION_LIMIT - 64 * 1024**2
SCHEMA = 1
LAYERS = ("bitbake", "openembedded-core", "meta-clang", "meta-openembedded", "meta-freescale")
PRIORITY = ("rust-native", "clang-native", "llvm-native", "lld-native", "cargo-native", "gcc-cross", "binutils-cross")
FILE_RE = re.compile(r"(?:[A-Za-z0-9][A-Za-z0-9_.+-]*/)?(?:[0-9a-f]{2}/){2}[A-Za-z0-9_.:+-]+\.(?:tar\.zst|tar\.zst\.siginfo)")


def stop(message):
    raise SystemExit(message)


def hash_files(files, root):
    h = hashlib.sha256()
    for p in sorted(files, key=lambda x: x.relative_to(root).as_posix()):
        h.update(p.relative_to(root).as_posix().encode() + b"\0")
        with p.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
        h.update(b"\0")
    return h.hexdigest()


def cache_keys(firmware):
    build = firmware / "build/airplay-probe-preflight/yocto"
    conf = build / "conf"
    if not all((conf / n).is_file() for n in ("local.conf", "bblayers.conf")):
        stop("Preflight must create Yocto configuration before cache key generation")
    pins = []
    for layer in LAYERS:
        rev = subprocess.check_output(["git", "-C", str(firmware / layer), "rev-parse", "HEAD"], text=True).strip()
        if not re.fullmatch(r"[0-9a-f]{40}", rev):
            stop("Invalid pinned layer revision: " + layer)
        pins.append(layer + "=" + rev)
    target_files = [conf / "local.conf", conf / "bblayers.conf"]
    target_files.extend(p for p in (firmware / "meta-catplay/conf").rglob("*.conf") if p.is_file() and not p.is_symlink())
    target = hash_files(target_files, firmware)
    scope = hashlib.sha256(("\n".join([f"schema={SCHEMA}", "os=ubuntu-22.04", "arch=x86_64", *pins, "target=" + target])).encode()).hexdigest()[:24]
    files = [firmware / "meta-catplay/recipes-apps" / name for name in ("catplay-airplay-probe.bb", "catplay-airplay-app.bb")]
    files.extend(p for p in (firmware / "meta-catplay").rglob("*.bbclass") if p.is_file() and not p.is_symlink())
    for layer in LAYERS:
        files.extend(p for p in (firmware / layer).rglob("*.bbclass") if p.is_file() and not p.is_symlink())
    recipe = hash_files(files, firmware)[:16]
    prefix = f"airplay-sstate-v{SCHEMA}-{scope}-"
    run = os.getenv("GITHUB_RUN_ID", "local")
    attempt = os.getenv("GITHUB_RUN_ATTEMPT", "1")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", run + "-" + attempt):
        stop("Invalid workflow run identity")
    return prefix, f"{prefix}{recipe}-{run}-{attempt}"


def direct_file(path, parent):
    try:
        if parent.is_symlink() or not safe_directory(parent, parent.parent):
            return False
        resolved = path.resolve()
        root = parent.resolve()
        if path.is_symlink() or not path.is_file() or not resolved.is_relative_to(root):
            return False
        current = path.parent
        while current != parent:
            if current.is_symlink():
                return False
            current = current.parent
        return True
    except OSError:
        return False


def safe_directory(path, boundary):
    try:
        absolute = path.absolute()
        base = boundary.absolute()
        absolute.relative_to(base)
        current = absolute
        while current != base:
            if current.is_symlink():
                return False
            current = current.parent
        return not base.is_symlink() and absolute.resolve().is_relative_to(base.resolve())
    except (OSError, ValueError):
        return False


def validate(cache):
    mp = cache / "manifest.json"
    if not direct_file(mp, cache):
        stop("Sstate cache manifest is missing or unsafe")
    try:
        m = json.loads(mp.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as e:
        stop(f"Cannot read sstate manifest: {e}")
    if not isinstance(m, dict) or m.get("schema") != SCHEMA or not isinstance(m.get("files"), list):
        stop("Unsupported sstate cache manifest")
    size = 0
    names = set()
    for item in m["files"]:
        if not isinstance(item, dict):
            stop("Invalid entry in sstate cache manifest")
        name = item.get("name", "")
        if not isinstance(name, str) or not FILE_RE.fullmatch(name):
            stop("Unsafe cached sstate entry")
        p = cache / name
        if not direct_file(p, cache) or name in names:
            stop("Unsafe cached sstate entry")
        names.add(name)
        actual = p.stat().st_size
        if isinstance(item.get("size"), bool) or not isinstance(item.get("size"), int) or actual != item["size"]:
            stop("Cached sstate size differs from manifest")
        size += actual
    if size != m.get("total_bytes") or size > LIMIT:
        stop("Cached sstate total is invalid or exceeds 4 GiB")
    archives = {name for name in names if name.endswith(".tar.zst")}
    sidecars = {name[:-len(".siginfo")] for name in names if name.endswith(".tar.zst.siginfo")}
    if not archives or archives != sidecars:
        stop("Cached sstate generation has incomplete archive/signature pairs")
    return m


def restore(firmware):
    root = firmware / "build/airplay-probe-preflight"
    if not safe_directory(root, firmware / "build"):
        stop("Preflight build directory escaped the firmware checkout")
    cache, sstate = root / "sstate-cache-input", root / "yocto/sstate-cache"
    if not cache.exists():
        print("No compatible hosted sstate generation was restored")
        return
    try:
        m = validate(cache)
    except SystemExit as e:
        print("Ignoring unusable cached sstate: " + str(e), file=sys.stderr)
        return
    build_root = root / "yocto"
    if not safe_directory(build_root, root):
        stop("Yocto build directory escaped the preflight root")
    sstate.mkdir(parents=True, exist_ok=True)
    if not safe_directory(sstate, build_root):
        stop("Sstate destination escaped the build root")
    copied = 0
    for item in m["files"]:
        src, dst = cache / item["name"], sstate / item["name"]
        if dst.exists() or dst.is_symlink():
            if dst.is_symlink() or not dst.is_file():
                stop("Unsafe existing sstate destination")
            continue
        if not safe_directory(dst.parent, sstate):
            stop("Sstate shard directory escaped the sstate root")
        dst.parent.mkdir(parents=True, exist_ok=True)
        if not safe_directory(dst.parent, sstate):
            stop("Sstate shard directory escaped the sstate root")
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)
        copied += dst.stat().st_size
    print(f"Restored {len(m['files'])} sstate files; copied {copied} bytes")


def rank(name):
    low = name.lower()
    return next((i for i, term in enumerate(PRIORITY) if term in low), len(PRIORITY))


def stage(firmware):
    root = firmware / "build/airplay-probe-preflight"
    if not safe_directory(root, firmware / "build"):
        stop("Preflight build directory escaped the firmware checkout")
    source, dest = root / "yocto/sstate-cache", root / "sstate-cache-input"
    marker = root / "probe-artifacts/bitbake-server-stop.txt"
    marker_dir = root / "probe-artifacts"
    if not safe_directory(marker_dir, root) or not direct_file(marker, marker_dir) or marker.read_text(encoding="utf-8").strip() != "stop_status=0":
        print("BitBake server stop was not confirmed; skipping sstate staging")
        output = os.getenv("GITHUB_OUTPUT")
        if output:
            with open(output, "a") as f:
                f.write("save=false\n")
        return False
    if not safe_directory(root / "yocto", root):
        stop("Yocto build directory escaped the preflight root")
    if dest.is_symlink():
        stop("Sstate staging directory is a symlink")
    dest.mkdir(parents=True, exist_ok=True)
    if not safe_directory(dest, root):
        stop("Sstate staging path escaped preflight build root")
    if source.exists() and not safe_directory(source, root / "yocto"):
        stop("Yocto sstate path is a symlink")
    if any(p.is_symlink() for p in dest.rglob("*")):
        stop("Unexpected symlink in sstate staging path")
    for p in dest.iterdir():
        if p.is_symlink():
            stop("Unexpected symlink in sstate staging path")
        if p.is_dir():
            shutil.rmtree(p)
        else:
            p.unlink()
    files = {}
    if source.is_dir():
        for p in source.rglob("*"):
            if p.is_symlink():
                stop("Symlink found in Yocto sstate directory")
            if direct_file(p, source) and FILE_RE.fullmatch(p.relative_to(source).as_posix()):
                files[p.relative_to(source).as_posix()] = p
    archives = [p for p in files.values() if p.name.endswith(".tar.zst")]
    pairs = []
    for p in archives:
        relative = p.relative_to(source).as_posix()
        side = files.get(relative + ".siginfo")
        if side:
            pairs.append((rank(p.name), -p.stat().st_mtime, p.name, p, side))
    pairs.sort()
    chosen, total, dropped = [], 0, []
    candidate_bytes = sum(p.stat().st_size for p in files.values())
    for r, _, name, archive, sig in pairs:
        size = archive.stat().st_size + sig.stat().st_size
        if total + size > LIMIT:
            dropped.append((name, size))
            continue
        chosen.append((archive, sig))
        total += size
    entries = []
    for archive, sig in chosen:
        for p in (archive, sig):
            relative = p.relative_to(source).as_posix()
            out = dest / relative
            out.parent.mkdir(parents=True, exist_ok=True)
            try:
                os.link(p, out)
            except OSError:
                shutil.copy2(p, out)
            entries.append({"name": relative, "size": out.stat().st_size})
    omitted = [{"archive": name, "bytes": size, "priority": rank(name) < len(PRIORITY)} for name, size in dropped]
    (dest / "manifest.json").write_text(json.dumps({"schema": SCHEMA, "source": "completed Yocto sstate objects", "candidate_file_count": len(files), "candidate_bytes": candidate_bytes, "total_bytes": total, "omitted_group_count": len(omitted), "omitted_groups": omitted, "files": entries}, indent=2, sort_keys=True) + "\n")
    print(f"Measured {len(files)} candidate cache files ({candidate_bytes} bytes); staged {len(chosen)} complete groups, {total} bytes (limit {LIMIT})")
    if dropped:
        print(f"{len(dropped)} complete groups omitted by size limit:", file=sys.stderr)
        for name, size in dropped[:30]:
            print(f"  {name}: {size} bytes", file=sys.stderr)
    save = bool(chosen)
    if not save:
        print("No complete sstate groups are available; cache save skipped")
    output = os.getenv("GITHUB_OUTPUT")
    if output:
        with open(output, "a") as f:
            f.write("save=" + ("true" if save else "false") + "\n")
    return save


def rotate(firmware):
    _, current = cache_keys(firmware)
    namespace = f"airplay-sstate-v{SCHEMA}-"
    token, repo = os.getenv("GITHUB_TOKEN"), os.getenv("GITHUB_REPOSITORY")
    if not token or not repo:
        print("Cache rotation skipped outside authorized Actions")
        return
    if repo != "keedle/catplay-firmware":
        print("Cache rotation skipped outside keedle/catplay-firmware")
        return
    base = f"https://api.github.com/repos/{repo}/actions/caches"
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    items, page = [], 1
    while True:
        url = base + "?" + urllib.parse.urlencode({"per_page": 100, "page": page})
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=30) as response:
            body = json.load(response)
        batch = body.get("actions_caches", [])
        items.extend(x for x in batch if isinstance(x.get("key"), str) and x["key"].startswith(namespace))
        if len(batch) < 100:
            break
        page += 1
    items.sort(key=lambda x: x.get("created_at", ""), reverse=True)
    if not any(item.get("key") == current for item in items):
        print("Current cache generation is not visible yet; preserving all existing generations")
        return
    keep, seen, total = [], set(), 0
    current_item = next(item for item in items if item.get("key") == current)
    current_size = current_item.get("size_in_bytes")
    if isinstance(current_size, int) and not isinstance(current_size, bool) and current_size <= GENERATION_LIMIT:
        keep.append(current_item)
        seen.add(current)
        total = current_size
    for item in items:
        key = item["key"]
        archive_size = item.get("size_in_bytes")
        if key == current or not isinstance(archive_size, int) or isinstance(archive_size, bool) or archive_size > GENERATION_LIMIT:
            continue
        if key not in seen and len(keep) < 2 and total + archive_size <= 8 * 1024**3:
            keep.append(item)
            seen.add(key)
            total += archive_size
    keep_ids = {item["id"] for item in keep[:2]}
    for item in items:
        if item.get("id") in keep_ids or not item.get("key", "").startswith(namespace):
            continue
        req = urllib.request.Request(base + "/" + str(int(item["id"])), method="DELETE", headers=headers)
        with urllib.request.urlopen(req, timeout=30) as response:
            if response.status not in (200, 204):
                stop("GitHub did not confirm deletion of an old owned generation")
    print(f"Rotated only {namespace}; retained {len(keep_ids)} generation(s), {total} archive bytes")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in {"keys", "restore", "stage", "rotate"}:
        stop("Usage: airplay-probe-sstate-cache.py {keys|restore|stage|rotate} FIRMWARE_ROOT")
    mode, firmware = sys.argv[1], Path(sys.argv[2]).resolve()
    if mode == "keys":
        prefix, generation = cache_keys(firmware)
        output = os.getenv("GITHUB_OUTPUT")
        if not output:
            stop("GITHUB_OUTPUT is required")
        with open(output, "a") as f:
            f.write(f"prefix={prefix}\ngeneration={generation}\n")
        print(f"Cache scope {prefix}; generation {generation}")
    elif mode == "restore":
        restore(firmware)
    elif mode == "stage":
        stage(firmware)
    else:
        rotate(firmware)


if __name__ == "__main__":
    main()
