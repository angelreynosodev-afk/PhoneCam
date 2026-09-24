# Compila phonecam.dll para OBS 31.0.0 (Windows x64). Pensado para GitHub Actions.
# No compila OBS: usa sus encabezados, el FFmpeg de obs-deps y una import lib
# generada a partir del obs.dll oficial.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ObsVersion = '31.0.0'
$DepsVersion = '2024-09-12'
$root = $PSScriptRoot
$ext = Join-Path $root 'ext'
$out = Join-Path $root 'out'
New-Item -ItemType Directory -Force $ext, $out | Out-Null
Set-Location $ext

Write-Host '== Descargando encabezados de OBS'
Invoke-WebRequest "https://github.com/obsproject/obs-studio/archive/refs/tags/$ObsVersion.zip" -OutFile obs-src.zip
tar -xf obs-src.zip "obs-studio-$ObsVersion/libobs" "obs-studio-$ObsVersion/deps/w32-pthreads"

Write-Host '== Descargando obs-deps (FFmpeg)'
Invoke-WebRequest "https://github.com/obsproject/obs-deps/releases/download/$DepsVersion/windows-deps-$DepsVersion-x64.zip" -OutFile deps.zip
New-Item -ItemType Directory -Force deps | Out-Null
tar -xf deps.zip -C deps include lib

Write-Host '== Descargando obs.dll oficial'
Invoke-WebRequest "https://github.com/obsproject/obs-studio/releases/download/$ObsVersion/OBS-Studio-$ObsVersion-Windows.zip" -OutFile obs-bin.zip
New-Item -ItemType Directory -Force obs-bin | Out-Null
tar -xf obs-bin.zip -C obs-bin "*/64bit/obs.dll"
$obsDll = Get-ChildItem obs-bin -Recurse -Filter obs.dll | Select-Object -First 1
if (-not $obsDll) { throw 'No se encontró obs.dll' }

Write-Host '== Entorno de Visual Studio'
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
& "$vs\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
Set-Location $ext

Write-Host '== Generando obs.lib'
$names = dumpbin /exports $obsDll.FullName |
	Select-String '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]{8}\s+(\S+)' |
	ForEach-Object { $_.Matches[0].Groups[1].Value }
if ($names.Count -lt 100) { throw "Muy pocos exports en obs.dll ($($names.Count))" }
@('LIBRARY obs', 'EXPORTS') + $names | Set-Content obs.def -Encoding ascii
lib /nologo /def:obs.def /machine:x64 /out:obs.lib
if ($LASTEXITCODE -ne 0) { throw 'lib falló' }

Write-Host '== Compilando phonecam.dll'
cl /nologo /O2 /MD /W3 /utf-8 /std:c17 /D_CRT_SECURE_NO_WARNINGS `
	/I "obs-studio-$ObsVersion\libobs" /I "obs-studio-$ObsVersion\deps\w32-pthreads" /I deps\include `
	"$root\phonecam.c" /LD /Fo"$out\\" /Fe"$out\phonecam.dll" `
	/link obs.lib deps\lib\avcodec.lib deps\lib\avutil.lib ws2_32.lib
if ($LASTEXITCODE -ne 0) { throw 'cl falló' }

Get-Item "$out\phonecam.dll"
