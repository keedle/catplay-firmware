# Reuse the reviewed artifact-only recipe and shipping c2a-rust-app ABI flags.
# No service, package installation, image, SDK or target execution is requested.
require catplay-airplay-probe.bb
SUMMARY = "Experimental integrated AirPlay application for supervised testing"
CARGO_SRC_DIR = "c2a/catplay_c2a"
CATPLAY_AIRPLAY_CARGO_NAME = "catplay_c2a"
CATPLAY_AIRPLAY_CARGO_KIND = "bin"
CATPLAY_AIRPLAY_CARGO_SELECT = "--bin catplay_c2a"
CATPLAY_AIRPLAY_ARTIFACT = "catplay-airplay-app-${MACHINE}"
CATPLAY_AIRPLAY_SOURCE_REV = "16160fbf59ca90b68ede634bacc01732d573a1fb"

# Actual C2A Cargo native dependencies. The shipping recipe's old FFmpeg,
# SDL, ALSA, opusenc and system FDK entries are not used by this source tree;
# its AAC Rust crates build their own bundled codec sources.
DEPENDS += "libusb1 x264 pixman libyuv dbus libjpeg-turbo"

# x264-sys invokes bindgen over the target C headers. Preserve the shipping
# recipe's sysroot fix without its unused FFmpeg compatibility scaffolding.
export BINDGEN_EXTRA_CLANG_ARGS = "--sysroot=${RECIPE_SYSROOT} -I${RECIPE_SYSROOT}/usr/include"
