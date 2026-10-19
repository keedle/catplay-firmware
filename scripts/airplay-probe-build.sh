#!/usr/bin/env bash
# Optional hosted build after the same job's successful preflight. Never run a
# target executable, contact a device, or request an image/SDK task here.
set -euo pipefail

if [[ $# != 0 ]]; then
    echo "Usage: $0 (after a successful same-job AirPlay probe preflight)" >&2
    exit 2
fi

firmware_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preflight_root="${firmware_root}/build/airplay-probe-preflight"
report_dir="${preflight_root}/reports"
build_dir="${preflight_root}/yocto"
artifact_dir="${preflight_root}/probe-artifacts"
source_rev="886bb2ad9b930c14e9a31e54c3671033e7934001"
resource_conf="${artifact_dir}/build-resource-controls.conf"
metadata_file="${artifact_dir}/build-metadata.json"
build_started=0
mkdir -p "$artifact_dir"
exec > >(tee "${artifact_dir}/build.log") 2>&1

finish() {
    result=$?
    trap - EXIT
    # Stop only this build directory's server, including a timed-out build.
    if [[ "$build_started" == 1 ]]; then
        timeout --signal=TERM --kill-after=5s 30s bitbake --kill-server \
            > "${artifact_dir}/server-stop.log" 2>&1 || true
    fi
    # Copy bounded tails of task logs, never run.do_* environment dumps or a
    # full BitBake environment. Keep files created by earlier workflow steps.
    python3 - "$build_dir" "$artifact_dir" "$metadata_file" <<'PY_LOGS' || true
import heapq
import json
from pathlib import Path
import sys
build, destination, metadata = map(Path, sys.argv[1:])
roots = list(build.glob('tmp*'))
if metadata.is_file():
    values = json.loads(metadata.read_text())
    root = Path(values.get('TMPDIR', build / 'tmp'))
    if root.resolve().is_relative_to(build.resolve()):
        roots.append(root)
logs = {}
for root in roots:
    for path in root.glob('work/*/*/*/temp/log.do_*'):
        if path.is_file():
            logs[str(path.resolve())] = path
selected = heapq.nlargest(20, logs.values(), key=lambda path: path.stat().st_mtime)
if selected:
    output = destination / 'task-log-tails'
    output.mkdir(exist_ok=True)
    index = []
    for number, path in enumerate(selected):
        with path.open('rb') as source:
            source.seek(max(0, path.stat().st_size - 2 * 1024**2))
            tail = source.read(2 * 1024**2)
        name = f'{number:02d}-{path.name}'
        (output / name).write_bytes(tail)
        index.append(f'{name}\t{path}\n')
    (output / 'index.txt').write_text(''.join(index))
PY_LOGS
    printf 'exit_status=%s\n' "$result" > "${artifact_dir}/result.txt"
    exit "$result"
}
trap finish EXIT

[[ "$(uname -s)" == Linux ]] || { echo "This helper requires a Linux build host."; exit 2; }
[[ $(id -u) != 0 ]] || { echo "Run BitBake as an ordinary user."; exit 2; }
for command in git python3 timeout free df nproc file; do
    command -v "$command" >/dev/null || { echo "Missing host command: $command"; exit 2; }
done
[[ -f "${report_dir}/result.txt" && "$(cat "${report_dir}/result.txt")" == exit_status=0 ]] || {
    echo "A successful same-job preflight is required."; exit 2;
}
[[ -z "$(git -C "$firmware_root" diff --name-only HEAD)" ]] || {
    echo "Tracked firmware metadata changed after checkout."; exit 2;
}
python3 - "$firmware_root" "$report_dir" "$build_dir" "$source_rev" <<'PY_VERIFY'
import hashlib
from pathlib import Path
import re
import subprocess
import sys
firmware, reports, build = map(Path, sys.argv[1:4])
expected_source = sys.argv[4]
pins = dict(line.split('=', 1) for line in (reports / 'source-pins.txt').read_text().splitlines() if '=' in line)
head = subprocess.check_output(['git', '-C', str(firmware), 'rev-parse', 'HEAD'], text=True).strip()
if pins.get('firmware_revision') != head or pins.get('catplay_revision') != expected_source:
    raise SystemExit('Preflight revisions do not match this build checkout')
for name in ['local.conf', 'bblayers.conf']:
    if (reports / name).read_bytes() != (build / 'conf' / name).read_bytes():
        raise SystemExit(f'Preflight configuration changed: {name}')
expected_hash = (reports / 'source-bundle.sha256').read_text().split()[0]
if not re.fullmatch(r'[0-9a-f]{64}', expected_hash):
    raise SystemExit('Invalid preflight bundle hash')
bundle = firmware / 'meta-catplay' / 'recipes-apps' / 'files' / 'catplay.tar.gz'
digest = hashlib.sha256()
with bundle.open('rb') as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        digest.update(chunk)
if digest.hexdigest() != expected_hash:
    raise SystemExit('Source bundle changed after preflight')
for name in ['bitbake', 'openembedded-core', 'meta-clang', 'meta-openembedded', 'meta-freescale']:
    expected = subprocess.check_output(['git', '-C', str(firmware), 'ls-tree', 'HEAD', '--', name], text=True).split()[2]
    actual = subprocess.check_output(['git', '-C', str(firmware / name), 'rev-parse', 'HEAD'], text=True).strip()
    if expected != actual:
        raise SystemExit(f'Gitlink changed after preflight: {name}')
recipes = set((reports / 'pn-buildlist').read_text().splitlines())
if not {'catplay-airplay-probe', 'openssl-slim', 'libopus', 'gcc-runtime'}.issubset(recipes):
    raise SystemExit('Preflight does not contain the required probe/runtime graph')
if recipes.intersection({'c2a-system-image', 'c2a-system-bundle'}):
    raise SystemExit('Full image/bundle dependency is outside this build scope')
PY_VERIFY

{
    uname -a
    nproc
    free -b
    df -Pk "$build_dir"
    df -Pi "$build_dir"
} > "${artifact_dir}/host-resources-before-build.txt"
python3 - "$build_dir" <<'PY_RESOURCES'
import os
import sys
with open('/proc/meminfo', encoding='ascii') as stream:
    mem = dict((line.split(':')[0], int(line.split()[1]) * 1024) for line in stream)
space = os.statvfs(sys.argv[1])
if mem['MemTotal'] < 12 * 1024**3 or mem['MemAvailable'] < 8 * 1024**3 or space.f_bavail * space.f_frsize < 50 * 1024**3 or space.f_favail < 400000:
    raise SystemExit('Best-effort build admission requires >=12 GiB total RAM, >=8 GiB available RAM, >=50 GiB free disk and >=400000 free inodes. Passing is not a cold Rust/LLVM build capacity guarantee.')
PY_RESOURCES

# Resource-only post-read settings. Preserve the exact ABI/target configuration
# whose bytes were checked against the preflight report above.
cat > "$resource_conf" <<'CONF'
BB_NUMBER_THREADS = "2"
BB_NUMBER_PARSE_THREADS = "2"
PARALLEL_MAKE = "-j 2"
export CARGO_BUILD_JOBS = "2"
BB_DISKMON_DIRS = "\
    STOPTASKS,${TMPDIR},5G,100K \
    STOPTASKS,${DL_DIR},5G,100K \
    STOPTASKS,${SSTATE_DIR},5G,100K \
    HALT,${TMPDIR},1G,20K \
    HALT,${DL_DIR},1G,20K \
    HALT,${SSTATE_DIR},1G,20K"
CONF
set +u
# shellcheck source=/dev/null
source "${firmware_root}/openembedded-core/oe-init-build-env" "$build_dir" "${firmware_root}/bitbake"
set -u
cd "$build_dir"
# Keep only values needed to validate target identity and locate our artifact.
timeout --signal=TERM --kill-after=30s 3m bitbake -R "$resource_conf" -e catplay-airplay-probe | \
    python3 -c '
import json, re, sys
allowed = set("MACHINE DISTRO DEFAULTTUNE TARGET_ARCH TCLIBC RUST_HOST_SYS RUST_TARGET_SYS RUST_BUILD_SYS STAGING_BINDIR_NATIVE CATPLAY_PROBE_RUSTC CATPLAY_PROBE_EXPECTED_RUST_RELEASE RUST_PANIC_STRATEGY TMPDIR DEPLOY_DIR_IMAGE RUSTFLAGS LDFLAGS RUST_LIBC_UNSTABLE_MUSL_V1_2_3 RUST_LIBC_UNSTABLE_GNU_TIME_BITS BB_NUMBER_THREADS PARALLEL_MAKE CARGO_BUILD_JOBS".split())
values = {}
for line in sys.stdin:
    match = re.fullmatch(r"(?:export )?([A-Z_0-9]+)=\"(.*)\"\n?", line)
    if match and match[1] in allowed:
        values[match[1]] = match[2]
json.dump(values, sys.stdout, indent=2, sort_keys=True)
print()
' > "$metadata_file"
python3 - "$metadata_file" "$build_dir" <<'PY_TARGET'
import json
from pathlib import Path
import sys
values = json.loads(Path(sys.argv[1]).read_text())
import re
for key, wanted in {'MACHINE': 'clk-mini-ultra-nor', 'DISTRO': 'c2a-musl', 'DEFAULTTUNE': 'mips32r2el', 'TCLIBC': 'musl', 'RUST_LIBC_UNSTABLE_MUSL_V1_2_3': '1', 'RUST_LIBC_UNSTABLE_GNU_TIME_BITS': '64', 'BB_NUMBER_THREADS': '2', 'PARALLEL_MAKE': '-j 2', 'CARGO_BUILD_JOBS': '2', 'CATPLAY_PROBE_EXPECTED_RUST_RELEASE': '1.94.1'}.items():
    if values.get(key) != wanted:
        raise SystemExit(f'Build configuration mismatch: {key}')
if '-fuse-ld=bfd' not in values.get('LDFLAGS', '') or '-Bstatic,-latomic,-Bdynamic' not in values.get('RUSTFLAGS', ''):
    raise SystemExit('Expected MIPS BFD/static atomic settings are missing')
root = Path(sys.argv[2]).resolve()
if not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+', values.get('RUST_BUILD_SYS', '')):
    raise SystemExit('Missing concrete native Rust build triple')
if values.get('CATPLAY_PROBE_RUSTC') != str(Path(values.get('STAGING_BINDIR_NATIVE', '')) / 'rustc'):
    raise SystemExit('Unexpected exported native Rust compiler path')
for key in ['TMPDIR', 'DEPLOY_DIR_IMAGE', 'STAGING_BINDIR_NATIVE']:
    path = Path(values[key]).resolve()
    if not path.is_relative_to(root):
        raise SystemExit(f'Unexpected path outside this preflight build: {key}')
PY_TARGET

build_started=1
timeout --signal=TERM --kill-after=30s 270m \
    bitbake -R "$resource_conf" -c deploy catplay-airplay-probe
python3 - "$metadata_file" "$artifact_dir" "$report_dir" <<'PY_ARTIFACTS'
import hashlib
import json
from pathlib import Path
import shutil
import re
import sys
metadata, destination, reports = map(Path, sys.argv[1:])
values = json.loads(metadata.read_text())
deployed = Path(values['DEPLOY_DIR_IMAGE'])
base = 'airplay-mirror-probe-clk-mini-ultra-nor'
required = [base, base + '.sha256', base + '.elf-header.txt', base + '.dynamic.txt', base + '.abi-attributes.txt', base + '.program-headers.txt', base + '.build-manifest.txt', base + '.rustc-version.txt']
for name in required:
    path = deployed / name
    if not path.is_file():
        raise SystemExit(f'Missing deployed probe artifact: {name}')
    shutil.copy2(path, destination / name)
manifest = dict(line.split('=', 1) for line in (destination / (base + '.build-manifest.txt')).read_text().splitlines() if '=' in line)
if manifest.get('source_bundle_sha256') != (reports / 'source-bundle.sha256').read_text().split()[0]:
    raise SystemExit('Deployed probe source hash differs from preflight')
for key, wanted in {'machine': 'clk-mini-ultra-nor', 'distro': 'c2a-musl', 'default_tune': 'mips32r2el', 'tclibc': 'musl', 'expected_catplay_git_revision': '886bb2ad9b930c14e9a31e54c3671033e7934001', 'rust_libc_unstable_musl_v1_2_3': '1', 'rust_libc_unstable_gnu_time_bits': '64'}.items():
    if manifest.get(key) != wanted:
        raise SystemExit(f'Deployed probe manifest mismatch: {key}')
for key, variable in {'target_arch': 'TARGET_ARCH', 'rust_host_sys': 'RUST_HOST_SYS', 'rust_target_sys': 'RUST_TARGET_SYS', 'rust_panic_strategy': 'RUST_PANIC_STRATEGY'}.items():
    if not values.get(variable) or manifest.get(key) != values[variable]:
        raise SystemExit(f'Deployed probe toolchain differs from build metadata: {key}')
# The compiler host is native; OE's RUST_HOST_SYS/RUST_TARGET_SYS above are
# the MIPS target for this recipe and must not be used as the compiler host.
lines = (destination / (base + '.rustc-version.txt')).read_text(encoding='utf-8').splitlines()
fields = {}
for line in lines[1:]:
    if ': ' in line:
        key, value = line.split(': ', 1)
        if key in fields:
            raise SystemExit('Duplicate rustc version field')
        fields[key] = value
release = fields.get('release', '')
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', release) or not lines or lines[0].split()[:2] != ['rustc', release]:
    raise SystemExit('Malformed rustc release report')
if release != values.get('CATPLAY_PROBE_EXPECTED_RUST_RELEASE') or manifest.get('expected_rustc_release') != release:
    raise SystemExit('Native rustc release differs from pinned compiler recipe')
for key, pattern in [('commit-hash', r'(?:[0-9a-f]{40}|unknown)'), ('commit-date', r'(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|unknown)')]:
    if not re.fullmatch(pattern, fields.get(key, '')):
        raise SystemExit('Invalid native rustc commit evidence')
compiler_host = fields.get('host', '')
if not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+', compiler_host) or compiler_host != values.get('RUST_BUILD_SYS') or manifest.get('rust_build_sys') != compiler_host:
    raise SystemExit('Native rustc host differs from build metadata')
compiler_path = str(Path(values['STAGING_BINDIR_NATIVE']) / 'rustc')
if values.get('CATPLAY_PROBE_RUSTC') != compiler_path or manifest.get('rustc_path') != compiler_path:
    raise SystemExit('Native rustc executable differs from exported compiler path')
for key, observed in {'rustc_release': release, 'rustc_commit_hash': fields['commit-hash'], 'rustc_commit_date': fields['commit-date'], 'rustc_host': compiler_host}.items():
    if manifest.get(key) != observed:
        raise SystemExit(f'Native rustc report differs from manifest: {key}')
with (destination / base).open('rb') as executable:
    header = executable.read(20)
if len(header) < 20 or header[:6] != b'\x7fELF\x01\x01' or int.from_bytes(header[18:20], 'little') != 8:
    raise SystemExit('Expected an ELF32 little-endian MIPS artifact')
expected = (destination / (base + '.sha256')).read_text().split()[0]
if hashlib.sha256((destination / base).read_bytes()).hexdigest() != expected:
    raise SystemExit('Deployed probe hash mismatch')
print('Probe compiled and its deployment reports were collected. Target execution and vehicle compatibility remain untested.')
PY_ARTIFACTS
file "${artifact_dir}/airplay-mirror-probe-clk-mini-ultra-nor" > "${artifact_dir}/host-file-identification.txt"
