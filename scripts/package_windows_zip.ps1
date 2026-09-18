#Requires -Version 5.1
<#
.SYNOPSIS
把 Flutter 的 Windows Release 目录打成可分发的 ZIP（含 app-local VC 运行库）。

.DESCRIPTION
把 `build\windows\x64\runner\Release` 的内容 + 三个 x64 VC 运行库打进
`build\windows\HaxShot-<版本>-windows-x64.zip`。

两条硬约束：

- **只打包，不重新构建**：调用前必须已经有 `flutter build windows --release` 的产物，
  脚本不会替你跑 flutter / cargo（计划 §52）；
- **缺文件必须 throw**：`Test-Path` 打印一个 False 不会让 CI 失败，所以每项缺失都抛异常，
  并且不静默跳过任何一项（§51.2 / §52）。

ZIP 里直接是 Release 目录的**内容**：解压后第一层就能看到 `hax_shot.exe`，不套一层目录。
CRT 只从 VS 的 redist 目录拷 `x64` 版本（`msvcp140.dll` / `vcruntime140.dll` /
`vcruntime140_1.dll`）；开发机/CI 上装了 VS **不能**证明干净机器能跑，必须在无 VS 的
Windows 上解压实测一次（docs/packaging.md 的「干净机器验证」）。

.PARAMETER Bundle
Release 目录。相对路径按仓库根解析。默认 `build\windows\x64\runner\Release`。

.PARAMETER OutputDirectory
ZIP 输出目录。默认 `build\windows`。

.PARAMETER SkipCrt
跳过 VC 运行库拷贝，只给“本地想看 ZIP 里有什么”的调试用。
**CI 与发布禁止使用**：跳过之后 ZIP 在没装 VC 运行库的机器上会启动失败。

.EXAMPLE
pwsh scripts/package_windows_zip.ps1
#>
[CmdletBinding()]
param(
    [string] $Bundle = 'build\windows\x64\runner\Release',
    [string] $OutputDirectory = 'build\windows',
    [switch] $SkipCrt
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$crtFileNames = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')

function Resolve-AgainstRepo {
    param([string] $Path)

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $repoRoot $Path)
}

function Get-AppVersion {
    $pubspec = Join-Path $repoRoot 'pubspec.yaml'
    $match = Select-String -Path $pubspec -Pattern '^version:\s*(.+)$' |
        Select-Object -First 1
    if (-not $match) { throw "pubspec.yaml 里找不到 version:（$pubspec）" }
    return $match.Matches.Groups[1].Value.Trim().Split('+')[0]
}

function Get-VcRuntimeDirectory {
    # 候选 1：VS 开发者命令行里已经设好的环境变量。
    if ($env:VCToolsRedistDir) {
        $direct = Get-ChildItem -Path $env:VCToolsRedistDir -Recurse -Directory `
            -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\' } |
            Sort-Object FullName -Descending
        if ($direct) { return $direct[0].FullName }
    }

    # 候选 2：vswhere 找 VS 安装目录，再进 VC\Redist\MSVC\<工具集版本>\x64\Microsoft.VC*.CRT。
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "找不到 vswhere.exe（$vswhere）：无法定位 VC 运行库。请安装「使用 C++ 的桌面开发」工作负载。"
    }

    $installPath = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if (-not $installPath) {
        $installPath = & $vswhere -latest -products * -property installationPath
    }
    if (-not $installPath) { throw 'vswhere 没找到带 VC 工具集的 Visual Studio 安装。' }

    $redistRoot = Join-Path $installPath 'VC\Redist\MSVC'
    $crtDirectories = Get-ChildItem -Path $redistRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            Get-ChildItem -Path (Join-Path $_.FullName 'x64') -Directory `
                -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue
        } |
        Sort-Object FullName -Descending
    if (-not $crtDirectories) { throw "在 $redistRoot 下找不到 x64 的 Microsoft.VC*.CRT。" }
    return $crtDirectories[0].FullName
}

$bundlePath = Resolve-AgainstRepo $Bundle
$outputPath = Resolve-AgainstRepo $OutputDirectory

if (-not (Test-Path $bundlePath)) {
    throw "Release 目录不存在：$bundlePath（先跑 flutter build windows --release）"
}
$bundlePath = (Resolve-Path $bundlePath).Path

$version = Get-AppVersion

# 1) app-local VC 运行库：先拷进 bundle，再跟其它文件一起进 ZIP。
if (-not $SkipCrt) {
    $crtSource = Get-VcRuntimeDirectory
    foreach ($name in $crtFileNames) {
        $source = Join-Path $crtSource $name
        if (-not (Test-Path $source)) { throw "VC 运行库缺文件：$source" }
        Copy-Item -Path $source -Destination (Join-Path $bundlePath $name) -Force
    }
    Write-Host "VC runtime: $crtSource"
}

# 2) 必需项：缺任何一项都是 bundle 不完整（§52）。
$required = @(
    'hax_shot.exe',
    'hax_shot_native.dll',
    'flutter_windows.dll',
    'data\app.so',
    'data\icudtl.dat',
    'data\flutter_assets'
)
if (-not $SkipCrt) { $required += $crtFileNames }
foreach ($item in $required) {
    if (-not (Test-Path (Join-Path $bundlePath $item))) { throw "Missing: $item" }
}

# 3) 插件 DLL 盘点到实际产物，不只手写六项（§51.1 / §52）。
$skipInPluginCount = @('hax_shot_native.dll', 'flutter_windows.dll') + $crtFileNames
$pluginDlls = Get-ChildItem $bundlePath -Filter *.dll |
    Where-Object { $_.Name -notin $skipInPluginCount }
if ($pluginDlls.Count -lt 5) {
    throw "Plugin DLLs look incomplete: found $($pluginDlls.Count)"
}
$pluginDlls | Select-Object -ExpandProperty Name | Sort-Object

# 4) data 目录必须真的有 AOT 与 assets。
if (-not (Get-ChildItem (Join-Path $bundlePath 'data\flutter_assets') -ErrorAction SilentlyContinue)) {
    throw 'data\flutter_assets is empty'
}

# 5) 打包：ZIP 里直接是 Release 目录的内容，不套一层。
if (-not (Test-Path $outputPath)) { New-Item -ItemType Directory -Path $outputPath | Out-Null }
$zip = Join-Path $outputPath "HaxShot-$version-windows-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $bundlePath '*') -DestinationPath $zip -CompressionLevel Optimal

# 6) 复查 ZIP：确认根下就是 hax_shot.exe（Windows PowerShell 的 Compress-Archive 会把
#    目录分隔符写成反斜杠，所以比对前统一成 `/`）。只查入口文件：目录项不一定有独立条目。
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
    foreach ($item in @('hax_shot.exe', 'hax_shot_native.dll')) {
        if ($entries -notcontains $item) { throw "ZIP 根下缺 $item（是不是多包了一层目录？）" }
    }
    $size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
    Write-Host "ZIP: $zip ($size MB, $($entries.Count) entries)"
} finally {
    $archive.Dispose()
}
