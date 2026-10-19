SUMMARY = "Opt-in receiver-only AirPlay diagnostic example, deployment artifact only"
# Experiment metadata only. This assigns no upstream license or distribution grant.
LICENSE = "CLOSED"

inherit catplay-src-bundle-local
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
S = "${UNPACKDIR}"
CARGO_SRC_DIR = "carplay/catplay_carplay"
DEPENDS += "openssl-slim libopus gcc-runtime"
COMPATIBLE_MACHINE = "^clk-mini-ultra-nor$"
PACKAGE_ARCH:ingenic-x1600 = "ingenic-x1600"
DEBUG_BUILD = "0"
CARGO_INSTALL_BENCHES = "0"

# Match the shipping app's MIPS ABI/linker settings. libc/libstd time64 settings
# come from c2a-rust-app and the same pinned distro/toolchain configuration.
RUSTFLAGS = " -C link-arg=-Wl,--gc-sections "
RUSTFLAGS:append:mipsel = " -C relocation-model=static -C link-arg=-no-pie -C link-arg=-Wl,-Bstatic,-latomic,-Bdynamic"
LDFLAGS:append:mipsel = " -fuse-ld=bfd"
LDFLAGS:remove:mipsel = "-fuse-ld=lld"

inherit c2a-rust-app deploy

# OE-core gitlink 5d1aa5c806c061a2994f4decb59016610f093213 supplies
# recipes-devtools/rust/rust_1.94.1.bb. The app recipe has no RUST_VERSION.
CATPLAY_PROBE_EXPECTED_RUST_RELEASE = "1.94.1"
CATPLAY_PROBE_RUSTC = "${STAGING_BINDIR_NATIVE}/rustc"

# Keep the package's existing dependency features; build only the gated example.
# The shared class authorizes Cargo network access as in the shipping recipe.
# --locked preserves the reviewed source Cargo.lock even though --frozen is removed.
do_compile() {
    # Cargo's RUSTC override selects the same staged native compiler we inspect.
    # Do not bypass an unexpected compiler wrapper and claim equivalent evidence.
    if [ -n "$RUSTC_WRAPPER" ] || [ -n "$RUSTC_WORKSPACE_WRAPPER" ] || \
        [ -n "$CARGO_BUILD_RUSTC_WRAPPER" ] || [ -n "$CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER" ]; then
        bbfatal "Unexpected Rust compiler wrapper in probe build"
    fi
    export RUSTC="${CATPLAY_PROBE_RUSTC}"
    "$RUSTC" --version --verbose > "${B}/probe-rustc-version.txt"
    python3 - "${B}/probe-rustc-version.txt" "${B}/probe-rustc-evidence.json" "$RUSTC" "${RUST_BUILD_SYS}" "${CATPLAY_PROBE_EXPECTED_RUST_RELEASE}" <<'PY_RUSTC'
import json
from pathlib import Path
import re
import sys
report, output = map(Path, sys.argv[1:3])
lines = report.read_text(encoding='utf-8').splitlines()
fields = {}
for line in lines[1:]:
    if ': ' in line:
        key, value = line.split(': ', 1)
        if key in fields:
            raise SystemExit('Duplicate rustc version field')
        fields[key] = value
release = fields.get('release', '')
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', release) or release != sys.argv[5]:
    raise SystemExit('Unexpected native rustc release')
if not lines or lines[0].split()[:2] != ['rustc', release]:
    raise SystemExit('Inconsistent rustc version banner')
if fields.get('host') != sys.argv[4] or not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+', sys.argv[4]):
    raise SystemExit('Native rustc host differs from RUST_BUILD_SYS')
for key, pattern in [('commit-hash', r'(?:[0-9a-f]{40}|unknown)'), ('commit-date', r'(?:[0-9]{4}-[0-9]{2}-[0-9]{2}|unknown)')]:
    if not re.fullmatch(pattern, fields.get(key, '')):
        raise SystemExit('Invalid native rustc commit evidence')
evidence = {'rustc_path': sys.argv[3], 'rustc_release': release, 'rustc_commit_hash': fields['commit-hash'], 'rustc_commit_date': fields['commit-date'], 'rustc_host': fields['host']}
output.write_text(json.dumps(evidence, sort_keys=True, indent=2) + '\n')
PY_RUSTC
    oe_cargo_build --locked --example airplay_mirror_probe \
        --features experimental_airplay_mirroring \
        --message-format=json-render-diagnostics > "${B}/cargo-probe.jsonl"
    python3 - "${B}/cargo-probe.jsonl" "${B}/probe-executable.txt" <<'PY'
import json
import os
import sys
executables = set()
for line in open(sys.argv[1], encoding='utf-8'):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    target = event.get('target', {})
    path = event.get('executable')
    if event.get('reason') == 'compiler-artifact' and target.get('name') == 'airplay_mirror_probe' and 'example' in target.get('kind', []) and path:
        executables.add(path)
if len(executables) != 1:
    raise SystemExit('Expected exactly one compiler-reported probe executable')
path = executables.pop()
if not os.path.isfile(path) or not os.access(path, os.X_OK):
    raise SystemExit('Compiler-reported probe executable is missing')
with open(sys.argv[2], 'w', encoding='utf-8') as output:
    output.write(path + '\n')
PY
}

# Never add the probe to an image or create a service/startup script.
do_install() {
    :
}
ALLOW_EMPTY:${PN} = "1"

do_deploy() {
    probe_path="$(cat "${B}/probe-executable.txt")"
    install -d "${DEPLOYDIR}"
    install -m 0755 "$probe_path" "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}"
    ${READELF} -h "$probe_path" > "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.elf-header.txt"
    ${READELF} -d "$probe_path" > "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.dynamic.txt"
    ${READELF} -A "$probe_path" > "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.abi-attributes.txt"
    ${READELF} -l "$probe_path" > "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.program-headers.txt"
    cat > "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.build-manifest.txt" <<'MANIFEST'
recipe=${PN}-${PV}-${PR}
expected_catplay_git_revision=886bb2ad9b930c14e9a31e54c3671033e7934001
source_bundle_sha256=${CATPLAY_SRC_BUNDLE_SHA256}
machine=${MACHINE}
distro=${DISTRO}
default_tune=${DEFAULTTUNE}
tune_features=${TUNE_FEATURES}
target_arch=${TARGET_ARCH}
target_sys=${TARGET_SYS}
tclibc=${TCLIBC}
toolchain=${TOOLCHAIN}
expected_rustc_release=${CATPLAY_PROBE_EXPECTED_RUST_RELEASE}
rust_build_sys=${RUST_BUILD_SYS}
rust_host_sys=${RUST_HOST_SYS}
rust_target_sys=${RUST_TARGET_SYS}
rust_panic_strategy=${RUST_PANIC_STRATEGY}
rustflags=${RUSTFLAGS}
ldflags=${LDFLAGS}
rust_libc_unstable_musl_v1_2_3=${RUST_LIBC_UNSTABLE_MUSL_V1_2_3}
rust_libc_unstable_gnu_time_bits=${RUST_LIBC_UNSTABLE_GNU_TIME_BITS}
cargo_cfg_libc_unstable_musl_v1_2_3=${CARGO_CFG_LIBC_UNSTABLE_MUSL_V1_2_3}
cargo_cfg_libc_unstable_gnu_time_bits=${CARGO_CFG_LIBC_UNSTABLE_GNU_TIME_BITS}
MANIFEST
    install -m 0644 "${B}/probe-rustc-version.txt" "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.rustc-version.txt"
    python3 - "${B}/probe-rustc-evidence.json" "${DEPLOYDIR}/airplay-mirror-probe-${MACHINE}.build-manifest.txt" <<'PY_MANIFEST'
import json
from pathlib import Path
import sys
with Path(sys.argv[2]).open('a', encoding='utf-8') as manifest:
    for key, value in sorted(json.loads(Path(sys.argv[1]).read_text()).items()):
        manifest.write(f'{key}={value}\n')
PY_MANIFEST
    cd "${DEPLOYDIR}"
    sha256sum "airplay-mirror-probe-${MACHINE}" > "airplay-mirror-probe-${MACHINE}.sha256"
}
addtask deploy after do_compile before do_build
