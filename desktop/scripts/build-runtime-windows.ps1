# Build the self-contained runtime bundled into the Windows installer:
#
#   desktop\runtime\
#     ruby\      RubyInstaller (x64, UCRT) - relocatable, ships its own DLLs
#     app\       the Rails app with vendored gems and precompiled assets
#     postgres\  PostgreSQL server (zonky embedded binaries)
#     valkey\    valkey-server.exe + msys-2.0.dll (built by build-valkey-msys2.sh)
#     libvips\   libvips DLLs for image variants (sharp's prebuilt Windows build)
#     llama\     llama.cpp's llama-server (Vulkan, CPU fallback) for local AI models
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
$LlamaBuild = if ($env:LLAMA_BUILD) { $env:LLAMA_BUILD } else { "b11972" }  # ggml-org/llama.cpp release
$LlamaSha256 = "5f3fa9b3ec948e6cb1af3c8f1063fa39c79f58bb5dc9bb9dfb2db890d098508d"   # win-vulkan-x64, b11972

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

# Start it again the way the app does: with a config file using Windows paths.
# Valkey's own output goes to the console so a failure explains itself.
$vkTest = Join-Path $Work "valkey-config-test"
if (Test-Path $vkTest) { Remove-Item -Recurse -Force $vkTest }
New-Item -ItemType Directory -Force -Path $vkTest | Out-Null
$fwd = ($vkTest -replace '\\', '/')
@"
bind 127.0.0.1
protected-mode yes
port 6391
requirepass smoketest
dir "$fwd"
pidfile "$fwd/valkey.pid"
appendonly yes
appendfsync everysec
save ""
maxmemory-policy noeviction
daemonize no
"@ | Set-Content -Encoding ascii (Join-Path $vkTest "valkey.conf")
Get-Content (Join-Path $vkTest "valkey.conf")
$proc = Start-Process -FilePath $valkeyExe -ArgumentList "valkey.conf" -WorkingDirectory $vkTest -PassThru -NoNewWindow `
  -RedirectStandardOutput (Join-Path $vkTest "out.log") -RedirectStandardError (Join-Path $vkTest "err.log")
Start-Sleep -Seconds 3
$alive = -not $proc.HasExited
Write-Host "valkey with config file running: $alive (exit: $($proc.ExitCode))"
Get-Content (Join-Path $vkTest "out.log"), (Join-Path $vkTest "err.log") -ErrorAction SilentlyContinue
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
if (-not $alive) { throw "valkey-server.exe exits when started with a config file" }

# --- llama.cpp server ---------------------------------------------------------
Write-Host "==> llama-server ($LlamaBuild)"
$llamaZip = Join-Path $Work "src\llama-$LlamaBuild-win-vulkan-x64.zip"
Fetch "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaBuild/llama-$LlamaBuild-bin-win-vulkan-x64.zip" $llamaZip
if ($LlamaBuild -eq "b11972" -and (Get-FileHash $llamaZip -Algorithm SHA256).Hash.ToLower() -ne $LlamaSha256) {
  throw "llama.cpp download does not match its checksum"
}
$llamaTmp = Join-Path $Work "llama-extract"
if (Test-Path $llamaTmp) { Remove-Item -Recurse -Force $llamaTmp }
7z x $llamaZip "-o$llamaTmp" -y | Out-Null
$llamaDir = (Get-ChildItem $llamaTmp -Recurse -Filter "llama-server.exe" | Select-Object -First 1).DirectoryName
New-Item -ItemType Directory -Force -Path (Join-Path $Out "llama") | Out-Null
# Only the server and the DLLs it loads, not the CLI tools.
Copy-Item (Join-Path $llamaDir "llama-server.exe") (Join-Path $Out "llama")
Copy-Item (Join-Path $llamaDir "*.dll") (Join-Path $Out "llama")
if (Test-Path (Join-Path $llamaDir "LICENSE")) { Copy-Item (Join-Path $llamaDir "LICENSE") (Join-Path $Out "llama") }
& (Join-Path $Out "llama\llama-server.exe") --version
if ($LASTEXITCODE -ne 0) { throw "bundled llama-server.exe does not start" }

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

# Diagnose PostgreSQL connections from the bundled Ruby (pg gem), started the
# way the app starts it. Informational: it never fails the build.
Write-Host "==> PostgreSQL connection check"
$pgTest = Join-Path $Work "pg-connection-test"
if (Test-Path $pgTest) { Remove-Item -Recurse -Force $pgTest }
New-Item -ItemType Directory -Force -Path $pgTest | Out-Null
Set-Content -NoNewline -Encoding ascii (Join-Path $pgTest "pw") "diagpass"
& (Join-Path $Out "postgres\bin\initdb.exe") -D (Join-Path $pgTest "data") -U sure -A scram-sha-256 -E UTF8 --no-locale "--pwfile=$(Join-Path $pgTest 'pw')" | Out-Null
& (Join-Path $Out "postgres\bin\pg_ctl.exe") start -w -t 60 -D (Join-Path $pgTest "data") -l (Join-Path $pgTest "postgres.log") `
  -o "-p 6392 -c listen_addresses=127.0.0.1 -c unix_socket_directories= -c log_connections=on"
$env:BUNDLE_GEMFILE = Join-Path $Out "app\Gemfile"
$env:BUNDLE_PATH = Join-Path $Out "app\vendor\bundle"
& (Join-Path $Out "ruby\bin\ruby.exe") -rbundler/setup (Join-Path $PSScriptRoot "diagnose-pg-connections.rb") 6392 diagpass
Remove-Item Env:BUNDLE_GEMFILE, Env:BUNDLE_PATH
& (Join-Path $Out "postgres\bin\pg_ctl.exe") stop -D (Join-Path $pgTest "data") -m fast -w
Get-Content (Join-Path $pgTest "postgres.log") -Tail 25
$global:LASTEXITCODE = 0

$size = "{0:N0} MB" -f ((Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "==> Runtime ready: $Out ($size)"
