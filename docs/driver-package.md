# TBDF1 wasm driver package

This package contains the `gen1` driver for TBDF1, TBDF generation 1. A future
TBDF2 driver would be generation 2 and would have its own release sequence.

## Package contents

- `lib/tbdf1-wasm.a` is the WebAssembly C ABI static library. Its archive
  member is optimized LLVM bitcode and supports link-time optimization.
- `include/tbdf1.h` declares the C ABI.
- `LICENSE` contains the project license.
- `SHA256SUMS.txt` contains the archive's SHA-256 checksum.
- `BUILD-METADATA.json` records the format generation, target, Zig version,
  optimization mode, LTO status, archive size, and checksum.

The archive targets `wasm32-freestanding`; it is a library, not a standalone
WebAssembly program. C consumers include `tbdf1.h` and link
`lib/tbdf1-wasm.a` with a compatible WebAssembly toolchain that supports LLVM
bitcode and LTO. The release ZIP omits source and documentation; GitHub's
tagged source archives provide the source.

Build the release package from the repository root with:

```powershell
.\build-release.ps1 -Generation gen1
```

The script writes build intermediates under `build/gen1/` and produces both an
uncompressed package directory and a ZIP under `release/`.
