#!/usr/bin/env bash
# Parse/graph only. This script never invokes a target compile, image or SDK task.
set -euo pipefail

if [[ $# != 1 ]]; then
    echo "Usage: $0 <clean-catplay-checkout>" >&2
    exit 2
fi

firmware_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_root="$(cd "$1" && pwd)"
preflight_root="${firmware_root}/build/airplay-probe-preflight"
report_dir="${preflight_root}/reports"
build_dir="${preflight_root}/yocto"
source "${firmware_root}/scripts/airplay-build-selection.sh"
required_pins=(bitbake openembedded-core meta-clang meta-openembedded meta-freescale)
mkdir -p "$report_dir" "$build_dir/conf"
exec > >(tee "${report_dir}/preflight.log") 2>&1
trap 'result=$?; printf "exit_status=%s\n" "$result" > "${report_dir}/result.txt"; exit "$result"' EXIT

[[ "$(uname -s)" == Linux ]] || { echo "This preflight requires a Linux host."; exit 2; }
[[ $(id -u) != 0 ]] || { echo "Run BitBake as an ordinary user."; exit 2; }
[[ "${CATPLAY_PROBE_SOURCE_REV:-$source_rev}" == "$source_rev" ]] || { echo "Unexpected source pin override."; exit 2; }
for command in git python3 tar gzip sha256sum timeout free df nproc; do
    command -v "$command" >/dev/null || { echo "Missing host command: $command"; exit 2; }
done
{
    uname -a
    nproc
    free -b
    df -Pk "$firmware_root"
    df -Pi "$firmware_root"
} > "${report_dir}/host-resources.txt"
python3 - "$firmware_root" <<'PY'
import os
import sys
with open('/proc/meminfo', encoding='ascii') as stream:
    mem = dict((line.split(':')[0], int(line.split()[1]) * 1024) for line in stream)
stat = os.statvfs(sys.argv[1])
if mem['MemTotal'] < 4 * 1024**3 or mem['MemAvailable'] < 2 * 1024**3 or stat.f_bavail * stat.f_frsize < 10 * 1024**3 or stat.f_favail < 100000:
    raise SystemExit('Parse preflight requires >=4 GiB total RAM, >=2 GiB available RAM, >=10 GiB free disk and >=100000 free inodes; this is not a compile capacity claim.')
PY

[[ "$(git -C "$source_root" rev-parse HEAD)" == "$source_rev" ]] || { echo "CatPlay source is not the reviewed full SHA."; exit 2; }
[[ -z "$(git -C "$source_root" status --porcelain --untracked-files=all)" ]] || { echo "CatPlay checkout must be clean, including untracked files."; exit 2; }
[[ -d "${source_root}/.git" ]] || { echo "Source-bundle helper requires a normal checkout, not a worktree."; exit 2; }
{
    printf 'firmware_revision=%s\n' "$(git -C "$firmware_root" rev-parse HEAD)"
    printf 'catplay_revision=%s\n' "$source_rev"
    printf 'airplay_recipe=%s\n' "$airplay_recipe"
    git -C "$firmware_root" ls-tree HEAD | awk '$1 == "160000" { print }'
} > "${report_dir}/source-pins.txt"

# Update exact gitlinks. Never follow the branch hints in .gitmodules or README.
timeout --signal=TERM --kill-after=30s 10m \
    git -C "$firmware_root" submodule update --init --depth 1 --jobs 2 -- "${required_pins[@]}"
for pin in "${required_pins[@]}"; do
    expected="$(git -C "$firmware_root" ls-tree HEAD -- "$pin" | awk '{print $3}')"
    actual="$(git -C "${firmware_root}/${pin}" rev-parse HEAD)"
    [[ "$expected" == "$actual" ]] || { echo "Gitlink mismatch: $pin"; exit 2; }
    printf '%s %s\n' "$pin" "$actual" >> "${report_dir}/initialized-pins.txt"
done
printf '%s\n' 'meta-rust and meta-lts-mixins-rust are not enabled; this configuration uses pinned OE-Core Cargo/Rust classes.' \
    > "${report_dir}/rust-layer-selection.txt"

bash "${firmware_root}/meta-catplay/scripts/create-src-bundle.sh" "$source_root"
bundle="${firmware_root}/meta-catplay/recipes-apps/files/catplay.tar.gz"
sha256sum "$bundle" > "${report_dir}/source-bundle.sha256"
tar -tzf "$bundle" > "${report_dir}/source-bundle-members.txt"
# A second clean-source bundle must have exactly the same bytes.
first_hash="$(sha256sum "$bundle" | awk '{print $1}')"
bash "${firmware_root}/meta-catplay/scripts/create-src-bundle.sh" "$source_root"
[[ "$first_hash" == "$(sha256sum "$bundle" | awk '{print $1}')" ]] || { echo "Source bundle is not deterministic."; exit 2; }

layers=(
    openembedded-core/meta
    meta-clang
    meta-openembedded/meta-oe
    meta-openembedded/meta-python
    meta-openembedded/meta-networking
    meta-openembedded/meta-multimedia
    meta-freescale
    meta-carplay
    meta-catplay
    meta-carlinkit
    meta-carlinkit-mini
)
{
    printf 'POKY_BBLAYERS_CONF_VERSION = "2"\nBBPATH = "${TOPDIR}"\nBBFILES ?= ""\nBBLAYERS = " \\\n'
    for layer in "${layers[@]}"; do
        [[ -f "${firmware_root}/${layer}/conf/layer.conf" ]] || { echo "Missing layer: $layer" >&2; exit 2; }
        printf '  %s \\\n' "${firmware_root}/${layer}"
    done
    printf '"\n'
} > "${build_dir}/conf/bblayers.conf"
cat > "${build_dir}/conf/local.conf" <<'CONF'
require conf/local/include/c2a/common.conf
require conf/local/include/c2a/git-config.conf
require conf/local/include/c2a/reproducible-build.conf
MACHINE = "clk-mini-ultra-nor"
DISTRO = "c2a-musl"
BB_NUMBER_THREADS = "2"
PARALLEL_MAKE = "-j 2"
CONF
cp "${build_dir}/conf/bblayers.conf" "${build_dir}/conf/local.conf" "$report_dir/"

# oe-init-build-env is a shell fragment and may reference unset variables.
set +u
# shellcheck source=/dev/null
source "${firmware_root}/openembedded-core/oe-init-build-env" "$build_dir" "${firmware_root}/bitbake"
set -u
cd "$build_dir"
timeout --signal=TERM --kill-after=30s 3m bitbake-layers show-layers > "${report_dir}/layers.txt"
timeout --signal=TERM --kill-after=30s 8m bitbake -p
timeout --signal=TERM --kill-after=30s 5m bitbake -g "$airplay_recipe"
for graph in pn-buildlist recipe-depends.dot task-depends.dot; do
    [[ ! -f "$graph" ]] || cp "$graph" "$report_dir/"
done
python3 - "${report_dir}/pn-buildlist" "$airplay_recipe" <<'PY_GRAPH'
import sys
with open(sys.argv[1], encoding='utf-8') as stream:
    recipes = {line.strip() for line in stream}
required = {sys.argv[2], 'openssl-slim', 'libopus', 'gcc-runtime'}
if sys.argv[2] == 'catplay-airplay-app':
    required.update({'libusb1', 'x264', 'pixman', 'libyuv', 'dbus', 'libjpeg-turbo'})
if not required.issubset(recipes):
    raise SystemExit('Missing required probe/runtime graph entries: ' + ', '.join(sorted(required - recipes)))
if recipes.intersection({'c2a-system-image', 'c2a-system-bundle'}):
    raise SystemExit('Unexpected full image/bundle in probe dependency graph')
PY_GRAPH
# Do not archive bitbake -e output: it can contain host credentials/environment.
timeout --signal=TERM --kill-after=30s 3m bitbake -e "$airplay_recipe" | \
    python3 -c '
import re, sys
allowed = set("MACHINE DISTRO DEFAULTTUNE TUNE_FEATURES TARGET_ARCH TARGET_SYS TARGET_OS TCLIBC TOOLCHAIN RUST_HOST_SYS RUST_TARGET_SYS RUST_VERSION RUST_PANIC_STRATEGY RUSTFLAGS LDFLAGS DEPENDS CARGO_BUILD_FLAGS CARGO_SRC_DIR CATPLAY_AIRPLAY_SOURCE_REV CATPLAY_AIRPLAY_ARTIFACT RUST_LIBC_UNSTABLE_MUSL_V1_2_3 RUST_LIBC_UNSTABLE_GNU_TIME_BITS CARGO_CFG_LIBC_UNSTABLE_MUSL_V1_2_3 CARGO_CFG_LIBC_UNSTABLE_GNU_TIME_BITS".split())
for line in sys.stdin:
    match = re.match(r"(?:export )?([A-Z_0-9]+)=", line)
    if match and match[1] in allowed:
        print(line, end="")
' > "${report_dir}/target-toolchain.txt"
python3 - "${report_dir}/target-toolchain.txt" "$source_rev" "$artifact_base" <<'PY'
import re, sys
values = {}
for line in open(sys.argv[1], encoding='utf-8'):
    match = re.match(r'(?:export )?([A-Z_0-9]+)="(.*)"$', line.rstrip())
    if match:
        values[match[1]] = match[2]
for key, wanted in {'CATPLAY_AIRPLAY_SOURCE_REV': sys.argv[2], 'CATPLAY_AIRPLAY_ARTIFACT': sys.argv[3], 'MACHINE': 'clk-mini-ultra-nor', 'DISTRO': 'c2a-musl', 'DEFAULTTUNE': 'mips32r2el', 'TCLIBC': 'musl', 'RUST_LIBC_UNSTABLE_MUSL_V1_2_3': '1', 'RUST_LIBC_UNSTABLE_GNU_TIME_BITS': '64'}.items():
    if values.get(key) != wanted:
        raise SystemExit(f'Target metadata mismatch: {key}')
if '-fuse-ld=bfd' not in values.get('LDFLAGS', '') or '-Bstatic,-latomic,-Bdynamic' not in values.get('RUSTFLAGS', ''):
    raise SystemExit('Expected MIPS BFD/static atomic settings are missing')
PY
printf '%s\n' 'Preflight parsed the pinned recipe and dependency graph. No target compilation, firmware image, SDK, installation or device operation ran.'
