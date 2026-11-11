# Build the self-contained runtime bundled into the Windows installer:
#
#   desktop\runtime\
#     ruby\      RubyInstaller (x64, UCRT) - relocatable, ships its own DLLs
#     app\       the Rails app with vendored gems and precompiled assets
#     postgres\  PostgreSQL server (zonky embedded binaries)
#     valkey\    valkey-server.exe + msys-2.0.dll (built by build-valkey-msys2.sh)
#     ssl\       CA bundle for outbound HTTPS
#
# Requirements: Windows x64, Git for Windows (bash + tar), 7-Zip on PATH, and
# MSYS2 at C:\msys64 with the UCRT toolchain (RubyInstaller compiles native gems
# with it). Run build-valkey-msys2.sh first; it writes desktop\build\valkey.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Desktop = Resolve-Path (Join-Path $PSScriptRoot "..")
$Repo = Resolve-Path (Join-Path $Desktop "..")
$RubyVersion = (Get-Content (Join-Path $Repo ".ruby-version")).Trim()
$RubyInstallerRelease = if ($env:RUBYINSTALLER_RELEASE) { $env:RUBYINSTALLER_RELEASE } else { "$RubyVersion-1" }
$PostgresVersion = if ($env:POSTGRES_VERSION) { $env:POSTGRES_VERSION } else { "17.11.0" }

$Work = Join-Path $Desktop "build\runtime-windows"
$Out = Join-Path $Desktop "runtime"
New-Item -ItemType Directory -Force -Path (Join-Path $Work "src") | Out-Null
if (Test-Path $Out) { Remove-Item -Recurse -Force $Out }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

function Fetch($Url, $Dest) {
  if (-not (Test-Path $Dest)) {
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile "$Dest.part" -MaximumRetryCount 3
    Move-Item "$Dest.part" $Dest
  }
}

# --- Ruby ---------------------------------------------------------------------
Write-Host "==> RubyInstaller $RubyInstallerRelease"
$rubyArchive = Join-Path $Work "src\rubyinstaller-$RubyInstallerRelease-x64.7z"
Fetch "https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-$RubyInstallerRelease/rubyinstaller-$RubyInstallerRelease-x64.7z" $rubyArchive
$rubyTmp = Join-Path $Work "ruby-extract"
if (Test-Path $rubyTmp) { Remove-Item -Recurse -Force $rubyTmp }
7z x $rubyArchive "-o$rubyTmp" -y | Out-Null
Move-Item (Get-ChildItem $rubyTmp -Directory | Select-Object -First 1).FullName (Join-Path $Out "ruby")
Remove-Item -Recurse -Force (Join-Path $Out "ruby\share\doc") -ErrorAction SilentlyContinue
& (Join-Path $Out "ruby\bin\ruby.exe") -ropenssl -e 'puts OpenSSL::OPENSSL_LIBRARY_VERSION'
if ($LASTEXITCODE -ne 0) { throw "bundled ruby does not start" }

# --- PostgreSQL ---------------------------------------------------------------
Write-Host "==> PostgreSQL $PostgresVersion"
$pgJar = Join-Path $Work "src\postgres-$PostgresVersion.jar"
Fetch "https://repo1.maven.org/maven2/io/zonky/test/postgres/embedded-postgres-binaries-windows-amd64/$PostgresVersion/embedded-postgres-binaries-windows-amd64-$PostgresVersion.jar" $pgJar
$pgTmp = Join-Path $Work "pg-extract"
if (Test-Path $pgTmp) { Remove-Item -Recurse -Force $pgTmp }
7z x $pgJar "-o$pgTmp" "*.txz" -r -y | Out-Null
$txz = Get-ChildItem $pgTmp -Recurse -Filter *.txz | Select-Object -First 1
7z x $txz.FullName "-o$pgTmp" -y | Out-Null
$tar = Get-ChildItem $pgTmp -Recurse -Filter *.tar | Select-Object -First 1
7z x $tar.FullName "-o$(Join-Path $Out 'postgres')" -y | Out-Null
foreach ($p in @("include", "share\doc", "share\locale", "lib\pgxs", "lib\pkgconfig")) {
  Remove-Item -Recurse -Force (Join-Path $Out "postgres\$p") -ErrorAction SilentlyContinue
}
if (-not (Test-Path (Join-Path $Out "postgres\share\extension\pgcrypto.control")) -and
    -not (Test-Path (Join-Path $Out "postgres\share\postgresql\extension\pgcrypto.control"))) {
  throw "pgcrypto extension missing from the PostgreSQL bundle"
}

# --- Valkey -------------------------------------------------------------------
$valkeyBuild = Join-Path $Desktop "build\valkey"
if (-not (Test-Path (Join-Path $valkeyBuild "valkey-server.exe"))) {
  throw "valkey-server.exe not found in $valkeyBuild - run build-valkey-msys2.sh first"
}
Copy-Item -Recurse $valkeyBuild (Join-Path $Out "valkey")

# --- CA certificates ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Join-Path $Out "ssl") | Out-Null
Fetch "https://curl.se/ca/cacert.pem" (Join-Path $Work "src\cacert.pem")
Copy-Item (Join-Path $Work "src\cacert.pem") (Join-Path $Out "ssl\cacert.pem")

# --- Rails app ----------------------------------------------------------------
# Git for Windows' bash runs the shared staging script with the bundled Ruby.
$bash = Join-Path ${env:ProgramFiles} "Git\bin\bash.exe"
$rubyBin = (Join-Path $Out "ruby\bin") -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
$appOut = (Join-Path $Out "app") -replace '\\', '/' -replace '^([A-Za-z]):', '/$1'
$script = (Join-Path $PSScriptRoot "stage-app.sh") -replace '\\', '/'
& $bash $script $rubyBin $appOut "x64-mingw-ucrt"
if ($LASTEXITCODE -ne 0) { throw "staging the Rails app failed" }

$size = "{0:N0} MB" -f ((Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "==> Runtime ready: $Out ($size)"
