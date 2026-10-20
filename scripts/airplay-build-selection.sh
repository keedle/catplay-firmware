#!/usr/bin/env bash
# Two explicit artifact targets share the same ABI/toolchain and build cache.
case "${CATPLAY_AIRPLAY_TARGET:-probe}" in
  probe)
    airplay_recipe=catplay-airplay-probe
    source_rev=886bb2ad9b930c14e9a31e54c3671033e7934001
    artifact_base=airplay-mirror-probe-clk-mini-ultra-nor
    ;;
  application)
    airplay_recipe=catplay-airplay-app
    source_rev=2dd1bb954757068cc5dfe49b089a7f195a536742
    artifact_base=catplay-airplay-app-clk-mini-ultra-nor
    ;;
  *) echo "Unsupported AirPlay build target" >&2; return 2 ;;
esac
