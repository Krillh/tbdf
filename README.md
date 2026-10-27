# TBDF (Tiny Basic Disk Format)

TBDF is a family of data formats for block-based persistent storage. They serve
as the official formats for [OpenWAC](https://github.com/Krillh/openwac). This
repository will contain all generations of TBDF.

For an archival format, see [TFAF](https://github.com/Krillh/tfaf).

| Generation | Docs, README | Description |
| --- | --- | --- |
| TBDF1 | [docs](docs/TBDF1.md), [README](gen1/README.md) | TBDF1 is TBDF generation 1, meant to be simple to implement, yet extendable and support very small volumes. |

## Release packages

Build the WebAssembly LTO archive and its consumer package with:

```powershell
.\build-release.ps1 -Generation gen1
```

Pass `-ReleaseVersion 0.1.0-rc.1` when preparing a versioned prerelease; the
bundle metadata records both the semantic version and its generation-specific
tag (`tbdf1/v0.1.0-rc.1`).

The package contains `lib/tbdf1-wasm.a` (an LLVM bitcode archive with LTO), the
public C header, license, checksum, and build metadata. It contains no source or
documentation; GitHub's tagged source archives provide the source. The script
places intermediates under `build/gen1/` and creates the package directory and
ZIP under `release/`. Each format generation has an independent release
sequence; add its configuration to `build-release.ps1` when a new generation is
implemented.
