$ErrorActionPreference = "Stop"
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
$envDump = cmd /c "`"$vs\VC\Auxiliary\Build\vcvars64.bat`" >nul && set"
foreach ($line in $envDump) { if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] } }
$root = if ($env:TC_ROOT) { $env:TC_ROOT } else { "C:\tc" }
cmake --build "$root\build" --target mmaps_generator 2>&1 | Select-Object -Last 25
if ($LASTEXITCODE -ne 0) { throw "build failed" }
Write-Host "BUILD OK"
