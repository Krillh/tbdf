param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('gen1')]
  [string]$Generation,
  [ValidatePattern('^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')]
  [string]$ReleaseVersion
)

$ErrorActionPreference = 'Stop'

$zig = (Get-Command zig -ErrorAction Stop).Source
$zigVersionOutput = & $zig version
if ($LASTEXITCODE -ne 0) { throw 'Could not query the Zig version.' }
$zigVersion = ($zigVersionOutput -join "`n").Trim()
$Generation = $Generation.ToLowerInvariant()
$generationConfig = @{
  gen1 = @{
    format_name = 'TBDF1'
    generation_number = 1
    release_tag_prefix = 'tbdf1'
    lto_archive = 'tbdf1-wasm.a'
    header = 'tbdf1.h'
  }
}[$Generation]
if ($null -eq $generationConfig) { throw "No build configuration for $Generation." }

$generationDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $Generation))
$buildDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "build/$Generation"))
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'release'))
$releaseName = "tbdf-$Generation-wasm"
$ltoBuildDir = Join-Path $buildDir 'lto'
$cacheDir = Join-Path $buildDir 'zig-cache'
$globalCacheDir = Join-Path $buildDir 'zig-global-cache'
$packageDir = Join-Path $releaseRoot $releaseName
$zipPath = Join-Path $releaseRoot "$releaseName.zip"
$stageName = ".$releaseName-stage-$([guid]::NewGuid().ToString('N'))"
$stageDir = Join-Path $releaseRoot $stageName
$stageZip = Join-Path $releaseRoot "$stageName.zip"

function Assert-ReleaseChild([string]$Path) {
  $fullPath = [IO.Path]::GetFullPath($Path)
  $prefix = $releaseRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) +
            [IO.Path]::DirectorySeparatorChar
  if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify a path outside the release directory: $fullPath"
  }
  return $fullPath
}

New-Item -ItemType Directory -Force -Path `
  $buildDir, $releaseRoot, $ltoBuildDir, $cacheDir, $globalCacheDir | Out-Null

# Keep the release build isolated from the developer's ordinary `zig build`
# output. The -flto archive stores LLVM bitcode in its archive member.
Push-Location $generationDir
$oldGlobalCacheDir = $env:ZIG_GLOBAL_CACHE_DIR
$oldLocalCacheDir = $env:ZIG_LOCAL_CACHE_DIR
try {
  # Set the cache locations through the supported environment variables. This
  # also works with Zig builds that initialize their package cache before
  # processing ordinary build options.
  $env:ZIG_GLOBAL_CACHE_DIR = $globalCacheDir
  $env:ZIG_LOCAL_CACHE_DIR = $cacheDir
  Push-Location $ltoBuildDir
  try {
    & $zig build-lib (Join-Path $generationDir 'src/c_api.zig') `
      '-target' 'wasm32-freestanding' `
      '-O' 'ReleaseFast' `
      '-flto'
    if ($LASTEXITCODE -ne 0) { throw "LTO archive build failed for $Generation." }
  }
  finally {
    Pop-Location
  }
}
finally {
  $env:ZIG_GLOBAL_CACHE_DIR = $oldGlobalCacheDir
  $env:ZIG_LOCAL_CACHE_DIR = $oldLocalCacheDir
  Pop-Location
}

$compilerArchive = Join-Path $ltoBuildDir 'libc_api.a'
$releaseArchive = Join-Path $ltoBuildDir $generationConfig.lto_archive
$publicHeader = Join-Path $generationDir "include/$($generationConfig.header)"
foreach ($requiredPath in @($compilerArchive, $publicHeader)) {
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    throw "Zig build did not produce the required release file: $requiredPath"
  }
}
Copy-Item -LiteralPath $compilerArchive -Destination $releaseArchive -Force

New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
New-Item -ItemType Directory -Force -Path `
  (Join-Path $stageDir 'include'), `
  (Join-Path $stageDir 'lib') | Out-Null

Copy-Item -LiteralPath $releaseArchive `
  -Destination (Join-Path $stageDir "lib/$($generationConfig.lto_archive)")
Copy-Item -LiteralPath $publicHeader `
  -Destination (Join-Path $stageDir "include/$($generationConfig.header)")
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'LICENSE') `
  -Destination (Join-Path $stageDir 'LICENSE')

$archives = @(
  @{ name = "lib/$($generationConfig.lto_archive)"; source = (Join-Path $stageDir "lib/$($generationConfig.lto_archive)") }
)
$archiveMetadata = @()
$checksumLines = @()
foreach ($archiveInfo in $archives) {
  $hash = (Get-FileHash -LiteralPath $archiveInfo.source -Algorithm SHA256).Hash.ToLowerInvariant()
  $size = (Get-Item -LiteralPath $archiveInfo.source).Length
  $archiveMetadata += [ordered]@{
    path = $archiveInfo.name
    type = 'LLVM bitcode static library archive with LTO enabled'
    size_bytes = $size
    sha256 = $hash
  }
  $checksumLines += "$hash  $($archiveInfo.name)"
}
$checksumLines | Set-Content -LiteralPath (Join-Path $stageDir 'SHA256SUMS.txt') -Encoding ascii

$metadata = [ordered]@{
  metadata_schema_version = 1
  format = $generationConfig.format_name
  driver_generation = $Generation
  format_generation_number = $generationConfig.generation_number
  release_name = $releaseName
  target_triple = 'wasm32-freestanding'
  optimization_mode = 'ReleaseFast with LTO'
  zig_version = $zigVersion
  archives = $archiveMetadata
  public_header = "include/$($generationConfig.header)"
}
if ($ReleaseVersion) {
  $metadata.release_version = $ReleaseVersion
  $metadata.release_tag = "$($generationConfig.release_tag_prefix)/v$ReleaseVersion"
}
$metadataJson = ConvertTo-Json -InputObject $metadata -Depth 5
[IO.File]::WriteAllText(
  (Join-Path $stageDir 'BUILD-METADATA.json'),
  $metadataJson + [Environment]::NewLine,
  [Text.UTF8Encoding]::new($false)
)

Compress-Archive -Path (Join-Path $stageDir '*') -DestinationPath $stageZip `
  -CompressionLevel Optimal

# Replace only this generation's named package and archive after staging both.
$safePackageDir = Assert-ReleaseChild $packageDir
$safeZipPath = Assert-ReleaseChild $zipPath
$safeStageDir = Assert-ReleaseChild $stageDir
$safeStageZip = Assert-ReleaseChild $stageZip
if (Test-Path -LiteralPath $safePackageDir) {
  Remove-Item -LiteralPath $safePackageDir -Recurse -Force
}
if (Test-Path -LiteralPath $safeZipPath) {
  Remove-Item -LiteralPath $safeZipPath -Force
}
Move-Item -LiteralPath $safeStageDir -Destination $safePackageDir
Move-Item -LiteralPath $safeStageZip -Destination $safeZipPath

Write-Host "Created $Generation wasm libraries under $buildDir"
Write-Host "Created release package: $packageDir"
Write-Host "Created release zip: $zipPath"
