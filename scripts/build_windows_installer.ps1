#Requires -Version 5.1
<#
.SYNOPSIS
把 Flutter 的 Windows Release bundle 编译成可分发的 Inno Setup 安装包（含 app-local VC 运行库）。

.DESCRIPTION
默认**自己构建 bundle**（`flutter build windows --release`；本机装了 fvm 就用 `fvm flutter`，
与 build_macos_dmg.sh / install_macos_app.sh 的约定一致，CI 里没有 fvm 就走 flutter-action
装好的 `flutter`），然后调 Inno Setup 6 编译 `packaging\hax_shot.iss`，产出：

    build\windows\HaxShot-<版本>-windows-x64-setup.exe

版本号只来自 pubspec.yaml（`+` 前那段），通过 /DAppVersion 传给 .iss，脚本和 .iss 里都不写死
版本。给了 -Bundle 就跳过构建、直接用现成产物（CI 已经构建过一次时用这个）。

和 ZIP 脚本共用 `scripts\windows_bundle.ps1` 的必需文件清单 / 插件盘点 / CRT 定位：

- **只打包，不重新构建**（-Bundle 时）——脚本不替你跑 cargo，构建交给 flutter build；
- **缺文件必须 throw**：bundle 必需项、ISCC 退出码、以及"产物到底有没有生成"任何一项不满足
  都抛异常，绝不留下一个看着成功、实际是空的安装包。

一条命令构建 + 一条命令验证（未来改版本后照这个顺序跑，见 docs/packaging.md）：

    pwsh scripts/build_windows_installer.ps1
    pwsh scripts/verify_windows_installer.ps1

.PARAMETER Bundle
Release 目录。**给了就跳过 flutter build**，相对路径按仓库根解析。
默认 `build\windows\x64\runner\Release`（不给时脚本会自己构建一遍）。

.PARAMETER OutputDirectory
安装包输出目录。默认 `build\windows`。

.PARAMETER Iscc
ISCC.exe 的路径。不给时依次找 PATH、`Program Files (x86)\Inno Setup 6`、
`Program Files\Inno Setup 6`、`%LOCALAPPDATA%\Programs\Inno Setup 6`。

.PARAMETER SkipCrt
跳过 VC 运行库拷贝，只给“本地想看安装包里有什么”的调试用。
**CI 与发布禁止使用**：跳过之后安装包在没装 VC 运行库的机器上会启动失败。

.EXAMPLE
pwsh scripts/build_windows_installer.ps1
# 构建 bundle + 编译安装包

.EXAMPLE
pwsh scripts/build_windows_installer.ps1 -Bundle build\windows\x64\runner\Release
# 不重新构建，只编译安装包
#>
[CmdletBinding()]
param(
    [string] $Bundle = 'build\windows\x64\runner\Release',
    [string] $OutputDirectory = 'build\windows',
    [string] $Iscc,
    [switch] $SkipCrt
)

$ErrorActionPreference = 'Stop'
# 中文输出统一成 UTF-8：不然管道/重定向到文件时 PowerShell 会按系统代码页（GBK）写出去，
# CI 日志会变成乱码。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows_bundle.ps1')

function Find-InnoCompiler {
    param([string] $Explicit)

    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "-Iscc 指定的路径不存在：$Explicit" }
        return (Resolve-Path $Explicit).Path
    }

    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' }
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
    }

    $onPath = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    throw @'
找不到 ISCC.exe（Inno Setup 6 的命令行编译器，需要 6.3+：ArchitecturesAllowed=x64compatible）。
装一个：winget install JRSoftware.InnoSetup / choco install innosetup，
或者用 -Iscc <路径> 指定（脚本只认 Inno Setup 6 的标准安装目录和 PATH）。
'@
}

# 1) bundle：给了 -Bundle 就直接用，否则自己构建（非交互，不等任何输入）。
if ($PSBoundParameters.ContainsKey('Bundle')) {
    Write-Host 'Bundle: 使用现有产物（跳过 flutter build）'
} else {
    $flutterArgs = @('build', 'windows', '--release')
    Push-Location $repoRoot
    try {
        if (Get-Command 'fvm' -ErrorAction SilentlyContinue) {
            Write-Host 'Bundle: fvm flutter build windows --release'
            & fvm flutter @flutterArgs
        } else {
            Write-Host 'Bundle: flutter build windows --release'
            & flutter @flutterArgs
        }
        if ($LASTEXITCODE -ne 0) { throw "flutter build windows --release 失败（exit $LASTEXITCODE）" }
    } finally {
        Pop-Location
    }
}

$bundlePath = Resolve-HaxShotPath -RepoRoot $repoRoot -Path $Bundle
$outputPath = Resolve-HaxShotPath -RepoRoot $repoRoot -Path $OutputDirectory

if (-not (Test-Path $bundlePath)) {
    throw "Release 目录不存在：$bundlePath（先跑 flutter build windows --release）"
}
$bundlePath = (Resolve-Path $bundlePath).Path

$version = Get-HaxShotAppVersion -RepoRoot $repoRoot

# 2) app-local VC 运行库：跟 ZIP 一样先拷进 bundle，安装包再把整个 bundle 收进去。
if (-not $SkipCrt) {
    $crtSource = Add-HaxShotVcRuntime -BundlePath $bundlePath
    Write-Host "VC runtime: $crtSource"
} else {
    Write-Warning '已跳过 VC 运行库（-SkipCrt）：这个安装包在没有 VC++ 运行库的机器上会启动失败，CI 与发布禁止使用。'
}

# 3) bundle 完整性：与 ZIP 脚本共用同一份清单和同一套检查（缺任何一项都 throw）。
$pluginDlls = Assert-HaxShotBundle -BundlePath $bundlePath -SkipCrt:$SkipCrt
Write-Host "Plugin DLLs: $($pluginDlls.Count)"

if (-not (Test-Path $outputPath)) { New-Item -ItemType Directory -Path $outputPath | Out-Null }

# 4) 编译安装包：版本 / bundle / 输出目录全部从命令行传入（.iss 里不写死）。
$isccPath = Find-InnoCompiler -Explicit $Iscc
$issPath = Join-Path $repoRoot 'packaging\hax_shot.iss'
$setupExe = Join-Path $outputPath "HaxShot-$version-windows-x64-setup.exe"
# 先删旧的：ISCC 失败时不能让我们读到上一次的产物，假装这次成功了。
if (Test-Path $setupExe) { Remove-Item $setupExe -Force }

Write-Host "ISCC: $isccPath"
& $isccPath "/DAppVersion=$version" "/DSourceDir=$bundlePath" "/DOutputDir=$outputPath" $issPath
if ($LASTEXITCODE -ne 0) { throw "ISCC 编译失败（exit $LASTEXITCODE）" }

# 5) 复查产物：不存在就是没编译出来，直接 throw（Test-Path 打印 False 不会让 CI 失败）。
if (-not (Test-Path $setupExe)) { throw "ISCC 说成功，但没有产物：$setupExe" }
$size = [math]::Round((Get-Item $setupExe).Length / 1MB, 1)
Write-Host "Setup: $setupExe ($size MB)"
