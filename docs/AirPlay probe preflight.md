# AirPlay probe target preflight

The `AirPlay probe target build` workflow uses a standard hosted Ubuntu runner in `keedle/catplay-firmware`. Development-branch pushes and manual runs with `build_probe=false` perform only the 35-minute configuration preflight for `clk-mini-ultra-nor`. A manual run with `build_probe=true` performs that same preflight and then attempts to compile the diagnostic probe, with a 330-minute job limit and a 270-minute compile timeout. No run builds a firmware image or SDK, or contacts a device.

The application source is pinned to `keedle/catplay` revision `886bb2ad9b930c14e9a31e54c3671033e7934001`. The firmware checkout supplies exact BitBake, OE-Core, Clang, OpenEmbedded and Freescale gitlinks. The stale Scarthgap README is not the version selector. The separate `meta-rust` and Scarthgap Rust mixin are intentionally excluded; the pinned OE-Core Cargo/Rust classes and the firmware's `c2a-rust-app` class provide the toolchain.

The script requires a clean application checkout, verifies the pin, creates the existing normalized source bundle twice and checks byte-for-byte determinism. It generates a separate build configuration for `c2a-musl` and `mips32r2el`, checks host resources, parses the metadata and saves the probe's dependency graph. The resource threshold is for parsing only. A successful parse does not establish that a standard runner can compile the Rust/LLVM target toolchain. The explicit compile stage requires at least 50 GiB free disk, 12 GiB total RAM and 8 GiB available RAM. These conservative admission checks do not guarantee that a cold build will finish. The build keeps two jobs and stops scheduling tasks if disk space drops below 5 GiB.

Reports contain source pins, bundle hashes and member names, layer selection, generated configuration, resource measurements, graph files and an allowlist of target/toolchain values. The full BitBake environment is never archived. Failure reports are uploaded too. Actual hosted parsing and target compilation remain unverified until their respective steps succeed. A compile request first records free disk space; if it is below 50 GiB, it removes only the stock Android, .NET and CodeQL directories from the disposable hosted runner and records free space again. It preserves the checkout and the native compiler, Python and Rust tools. If resources remain below the build threshold, the job fails before compilation and uploads the measurements.

`meta-catplay/recipes-apps/catplay-airplay-probe.bb` is a separate, machine-scoped recipe for the existing gated `airplay_mirror_probe` example. It preserves the application's default dependency features, uses OpenSSL slim, Opus and the GNU runtime for static atomic helpers, and copies the shipping app's MIPS non-PIE/BFD/static-atomic settings. The shared class and distro supply the time64 settings for libc and Rust's standard library. No generic downloaded musl binary or SDK is substituted.

The recipe installs no target files, startup service or image package inclusion. The explicit compile step runs only `bitbake -c deploy catplay-airplay-probe` and uploads the compiler-reported example executable, its hash, ELF header, ABI attributes, program headers, dynamic dependencies and a build manifest. Diagnostic artifacts also record failed or resource-blocked attempts. These reports must be checked against the installed target before the requested temporary bench test. A successful compile alone is not permission to flash firmware or proof of runtime compatibility. `LICENSE = "CLOSED"` marks this experiment's build metadata; it does not assign a license or grant distribution rights to upstream code.

## Reusing completed compiler dependencies

The first explicit compile on Ubuntu 22.04 reached native Clang/Cargo tasks but
hit the 120-minute wrapper timeout before the probe recipe compiled. It produced
no probe binary. The longer budget retains the same source revisions, target,
two BitBake tasks, compiler parallelism and resource admission checks.

Manual compile runs restore a compatible shared-state cache after preflight.
The cache scope includes the Ubuntu/architecture selection, exact five layer
revisions and target configuration. Recipe/class fingerprints and run identity
identify each new generation. BitBake task signatures still decide whether a
cached object can be reused; this does not substitute another SDK or sysroot.

After confirmed BitBake server shutdown, an always-run step stages complete
`.tar.zst`/`.tar.zst.siginfo` pairs, including native host-prefix directories.
Native Rust, LLVM/Clang/lld and Cargo objects have priority. The raw selection is
limited to 4 GiB minus archive overhead and includes a measured size manifest.
Oversized priority objects are reported. No full `tmp`, sysroots, Cargo home or
source downloads are included.

A successfully saved generation permits rotation within the workflow's own
cache namespace only, keeping at most two generations and 8 GiB. Rotation
checks the personal repository and confirms the new save is visible before
removing older entries. Missing or invalid cache contents fall back to a cold
build. Cache availability and actual reuse are only established by a hosted
run; full-job cancellation or timeout can still prevent the save steps.

The workflow's additional `actions: write` permission is used only by that
scoped cache rotation. It does not change repository settings or billing.
