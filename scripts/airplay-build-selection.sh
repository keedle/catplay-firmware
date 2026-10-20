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
    source_rev=16160fbf59ca90b68ede634bacc01732d573a1fb
    artifact_base=catplay-airplay-app-clk-mini-ultra-nor
    ;;
  *) echo "Unsupported AirPlay build target" >&2; return 2 ;;
esac
