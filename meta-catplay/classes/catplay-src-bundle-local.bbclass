# Bundle provided by CI/CD pipeline in meta-catplay/recipes-apps/files/catplay.tar.gz

CATPLAY_SRC_BUNDLE := "${THISDIR}/../recipes-apps/files/catplay.tar.gz"
CATPLAY_SRC_BUNDLE_SHA256 = ""

python __anonymous () {
    import hashlib
    import os

    bundle = d.getVar("CATPLAY_SRC_BUNDLE")
    if not bundle or not os.path.exists(bundle):
        return

    h = hashlib.sha256()
    with open(bundle, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    d.setVar("CATPLAY_SRC_BUNDLE_SHA256", h.hexdigest())
}

SRC_URI = "file://catplay.tar.gz"
SRC_URI[sha256sum] = "${CATPLAY_SRC_BUNDLE_SHA256}"
PR = "r3"
