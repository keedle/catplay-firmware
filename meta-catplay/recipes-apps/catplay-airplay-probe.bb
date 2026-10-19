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

# Keep the package's existing dependency features; build only the gated example.
# The shared class authorizes Cargo network access as in the shipping recipe.
# --locked preserves the reviewed source Cargo.lock even though --frozen is removed.
do_compile() {
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
rust_version=${RUST_VERSION}
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
    cd "${DEPLOYDIR}"
    sha256sum "airplay-mirror-probe-${MACHINE}" > "airplay-mirror-probe-${MACHINE}.sha256"
}
addtask deploy after do_compile before do_build
