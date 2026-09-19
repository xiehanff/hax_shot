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

必需文件清单 / CRT 定位这些跟安装包共用的部分在 `scripts/windows_bundle.ps1`：安装包
（`build_windows_installer.ps1`）用同一份函数，别在这里另抄一份清单。

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
. (Join-Path $PSScriptRoot 'windows_bundle.ps1')

$bundlePath = Resolve-HaxShotPath -RepoRoot $repoRoot -Path $Bundle
$outputPath = Resolve-HaxShotPath -RepoRoot $repoRoot -Path $OutputDirectory

if (-not (Test-Path $bundlePath)) {
    throw "Release 目录不存在：$bundlePath（先跑 flutter build windows --release）"
}
$bundlePath = (Resolve-Path $bundlePath).Path

$version = Get-HaxShotAppVersion -RepoRoot $repoRoot

# 1) app-local VC 运行库：先拷进 bundle，再跟其它文件一起进 ZIP。
if (-not $SkipCrt) {
    $crtSource = Add-HaxShotVcRuntime -BundlePath $bundlePath
    Write-Host "VC runtime: $crtSource"
}

# 2)–4) 必需项 / 插件 DLL 盘点 / data 目录非空：与安装包共用 windows_bundle.ps1 里的同一份
#        清单和同一套检查（缺任何一项都 throw）。
$pluginDlls = Assert-HaxShotBundle -BundlePath $bundlePath -SkipCrt:$SkipCrt
$pluginDlls

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
