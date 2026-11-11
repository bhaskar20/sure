# Build the self-contained runtime bundled into the Windows installer:
#
#   desktop\runtime\
#     ruby\      RubyInstaller (x64, UCRT) - relocatable, ships its own DLLs
#     app\       the Rails app with vendored gems and precompiled assets
#     postgres\  PostgreSQL server (zonky embedded binaries)
#     valkey\    valkey-server.exe + msys-2.0.dll (built by build-valkey-msys2.sh)
#     libvips\   libvips DLLs for image variants (sharp's prebuilt Windows build)
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
$SharpVersion = if ($env:SHARP_WIN32_VERSION) { $env:SHARP_WIN32_VERSION } else { "0.35.5" }  # @img/sharp-win32-x64

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
# Smoke test from a plain Windows process (as the app runs it): start, PING, stop.
$valkeyExe = Join-Path $Out "valkey\valkey-server.exe"
$proc = Start-Process -FilePath $valkeyExe -ArgumentList "--port 6390 --bind 127.0.0.1 --save `"`" --appendonly no" -PassThru -WindowStyle Hidden
$reply = ""
foreach ($i in 1..20) {
  Start-Sleep -Milliseconds 500
  try {
    $client = New-Object System.Net.Sockets.TcpClient("127.0.0.1", 6390)
    $stream = $client.GetStream()
    $bytes = [Text.Encoding]::ASCII.GetBytes("PING`r`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $buf = New-Object byte[] 64
    $n = $stream.Read($buf, 0, 64)
    $reply = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    $client.Close()
    break
  } catch { }
}
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Write-Host "Valkey PING reply: $reply"
if (-not $reply.StartsWith("+PONG")) { throw "bundled valkey-server.exe does not start" }

# --- libvips -----------------------------------------------------------------
Write-Host "==> libvips (sharp-win32-x64 $SharpVersion)"
$vipsTgz = Join-Path $Work "src\sharp-win32-x64-$SharpVersion.tgz"
Fetch "https://registry.npmjs.org/@img/sharp-win32-x64/-/sharp-win32-x64-$SharpVersion.tgz" $vipsTgz
$vipsTmp = Join-Path $Work "vips-extract"
if (Test-Path $vipsTmp) { Remove-Item -Recurse -Force $vipsTmp }
New-Item -ItemType Directory -Force -Path $vipsTmp, (Join-Path $Out "libvips") | Out-Null
tar -xzf $vipsTgz -C $vipsTmp
# ruby-vips loads libvips-42.dll by name, so the folder goes on the app's PATH.
Copy-Item (Join-Path $vipsTmp "package\lib\*.dll") (Join-Path $Out "libvips")
if (-not (Test-Path (Join-Path $Out "libvips\libvips-42.dll"))) { throw "libvips-42.dll missing" }

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
