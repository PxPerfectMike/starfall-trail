# Builds TrinityCore's map tools (mapextractor, vmap4extractor, vmap4assembler, mmaps_generator)
# patched for the WoW Forever client. Everything goes in $env:TC_ROOT (default C:\tc).
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$root = if ($env:TC_ROOT) { $env:TC_ROOT } else { "C:\tc" }
New-Item -ItemType Directory -Force $root | Out-Null
Set-Location $root

function Step($m) { Write-Host "=== $(Get-Date -Format HH:mm:ss) $m" }

# Boost 1.84 (static, prebuilt; same as TrinityCore's CI)
if (-not (Test-Path "$root\boost\include")) {
	Step "downloading Boost"
	Invoke-WebRequest "https://github.com/MarkusJx/prebuilt-boost/releases/download/1.84.0/boost-1.84.0-windows-2022-msvc-static-x86.tar.gz" -OutFile "$root\boost.tar.gz"
	New-Item -ItemType Directory -Force "$root\boost" | Out-Null
	tar -xzf "$root\boost.tar.gz" -C "$root\boost"
	Remove-Item "$root\boost.tar.gz"
}
Get-ChildItem "$root\boost" | Select-Object -First 5 Name | Out-Host

# OpenSSL 3/4 (installed into our folder)
if (-not (Test-Path "$root\openssl\include\openssl\ssl.h")) {
	Step "downloading OpenSSL"
	Invoke-WebRequest "https://slproweb.com/download/Win64OpenSSL-4_1_0.exe" -OutFile "$root\openssl.exe"
	Start-Process -Wait -FilePath "$root\openssl.exe" -ArgumentList "/VERYSILENT", "/SP-", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=$root\openssl"
	Remove-Item "$root\openssl.exe"
}

# TrinityCore master at the commit the patch was made against (newer commits may not take it).
$commit = "67816ef39a9d1f86b261021b8cf5e39c182f37f2"
if (-not (Test-Path "$root\src\.git")) {
	Step "cloning TrinityCore"
	git init "$root\src"
	git -C "$root\src" remote add origin https://github.com/TrinityCore/TrinityCore.git
	git -C "$root\src" fetch --depth 1 origin $commit
	git -C "$root\src" checkout FETCH_HEAD
	Step "applying the Forever patch"
	git -C "$root\src" apply "$PSScriptRoot\wayfinder-forever.patch"
	if ($LASTEXITCODE -ne 0) { throw "the patch did not apply" }
}

# Visual Studio environment
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
Step "VS at $vs"
$envDump = cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set"
foreach ($line in $envDump) { if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] } }

$boostRoot = (Get-ChildItem "$root\boost" -Directory | Where-Object { Test-Path "$($_.FullName)\include" } | Select-Object -First 1).FullName
if (-not $boostRoot) { $boostRoot = "$root\boost" }
Step "Boost root $boostRoot"

Step "configuring"
cmake -G Ninja -S "$root\src" -B "$root\build" -DCMAKE_BUILD_TYPE=Release -DTOOLS=ON -DSERVERS=OFF -DSCRIPTS=none -DWITH_WARNINGS=OFF `
	"-DBOOST_ROOT=$boostRoot" "-DOPENSSL_ROOT_DIR=$root\openssl"
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

Step "building tools"
cmake --build "$root\build" --target mapextractor vmap4extractor vmap4assembler mmaps_generator
if ($LASTEXITCODE -ne 0) { throw "build failed" }
Step "done"
Get-ChildItem "$root\build\bin" -Recurse -Include *.exe | Select-Object FullName, Length | Out-Host
