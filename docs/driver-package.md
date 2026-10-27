# TBDF1 wasm driver package

This package contains the `gen1` driver for TBDF1, TBDF generation 1. A future
TBDF2 driver would be generation 2 and would have its own release sequence.

## Package contents

- `lib/libtbdf1.a` is the WebAssembly C ABI static library.
- `include/tbdf1.h` declares the C ABI.
- `zig/` contains the Zig package sources and build manifest for consumers who
  want to import the typed Zig API directly.
- `docs/TBDF1.md` specifies the on-disk format.
- `LICENSE` contains the project license.
- `SHA256SUMS.txt` contains the C ABI library's SHA-256 checksum.
- `BUILD-METADATA.json` records the format generation, target, Zig version,
  optimization mode, archive sizes, and checksums.

The archive targets `wasm32-freestanding`; it is a library, not a standalone
WebAssembly program. C consumers link `libtbdf1.a` and include `tbdf1.h` using
a compatible WebAssembly toolchain. Zig consumers can use the source package in
`zig/` and configure their build for the target they need.

Build the release package from the repository root with:

```powershell
.\build-release.ps1 -Generation gen1
```

The script writes build intermediates under `build/gen1/` and produces both an
uncompressed package directory and a ZIP under `release/`.
