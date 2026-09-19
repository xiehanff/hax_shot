#Requires -Version 5.1
<#
.SYNOPSIS
Windows 打包共用的 bundle 完整性检查与 VC 运行库定位。

.DESCRIPTION
只定义函数、不做任何动作，由调用方点源导入：

    . (Join-Path $PSScriptRoot 'windows_bundle.ps1')

`package_windows_zip.ps1`（ZIP）和 `build_windows_installer.ps1`（Inno Setup 安装包）都从这里
取「必需文件清单 / 插件 DLL 盘点 / CRT 定位」。**两边的清单不能各写一份**：一旦漂移，就会出现
「ZIP 校验通过、安装包少文件」这种只在用户机器上才暴露的问题（计划 §51.1 / §52）。
#>

function Get-HaxShotAppVersion {
    <#
    .SYNOPSIS
    应用版本号：只来自 pubspec.yaml 的 `version:`，取 `+` 前那段（1.5.0+1 → 1.5.0）。
    #>
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $pubspec = Join-Path $RepoRoot 'pubspec.yaml'
    $match = Select-String -Path $pubspec -Pattern '^version:\s*(.+)$' |
        Select-Object -First 1
    if (-not $match) { throw "pubspec.yaml 里找不到 version:（$pubspec）" }
    return $match.Matches.Groups[1].Value.Trim().Split('+')[0]
}

function Resolve-HaxShotPath {
    <#
    .SYNOPSIS
    把相对路径按仓库根解析；绝对路径原样返回。
    #>
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot,

        [Parameter(Mandatory)]
        [string] $Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return (Join-Path $RepoRoot $Path)
}

function Get-HaxShotCrtFileNames {
    <#
    .SYNOPSIS
    app-local VC 运行库的三个 x64 文件（打包与校验共用这一份清单）。
    #>
    return @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
}

function Get-HaxShotVcRuntimeDirectory {
    <#
    .SYNOPSIS
    定位 VS 的 x64 `Microsoft.VC*.CRT` 目录（CRT 的来源）。
    #>
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

function Add-HaxShotVcRuntime {
    <#
    .SYNOPSIS
    把三个 x64 CRT 拷进 bundle，返回 CRT 源目录。

    .DESCRIPTION
    拷进 bundle 之后，ZIP 与安装包都会把它当成 bundle 的一部分一起收进去；
    缺任何一个文件直接 throw，不静默跳过。
    #>
    param(
        [Parameter(Mandatory)]
        [string] $BundlePath
    )

    $crtSource = Get-HaxShotVcRuntimeDirectory
    foreach ($name in (Get-HaxShotCrtFileNames)) {
        $source = Join-Path $crtSource $name
        if (-not (Test-Path $source)) { throw "VC 运行库缺文件：$source" }
        Copy-Item -Path $source -Destination (Join-Path $BundlePath $name) -Force
    }
    return $crtSource
}

function Assert-HaxShotBundle {
    <#
    .SYNOPSIS
    校验 bundle 完整：必需项、插件 DLL 数量、`data\flutter_assets` 非空。

    .DESCRIPTION
    `Test-Path` 打印一个 False 不会让 CI 失败，所以每项缺失都抛异常，并且不静默跳过任何
    一项（计划 §51.2 / §52）。返回插件 DLL 名字（已排序），方便调用方打印。

    .PARAMETER SkipCrt
    跳过 CRT 的必需项检查，只给「本地随便看看」的调试用；CI 与发布禁止使用。
    #>
    param(
        [Parameter(Mandatory)]
        [string] $BundlePath,

        [switch] $SkipCrt
    )

    $crtFileNames = Get-HaxShotCrtFileNames
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
        if (-not (Test-Path (Join-Path $BundlePath $item))) { throw "Missing: $item" }
    }

    # 插件 DLL 盘点到实际产物，不只手写六项（§51.1 / §52）。
    $skipInPluginCount = @('hax_shot_native.dll', 'flutter_windows.dll') + $crtFileNames
    $pluginDlls = Get-ChildItem $BundlePath -Filter *.dll |
        Where-Object { $_.Name -notin $skipInPluginCount }
    if ($pluginDlls.Count -lt 5) {
        throw "Plugin DLLs look incomplete: found $($pluginDlls.Count)"
    }

    # data 目录必须真的有 AOT 与 assets。
    if (-not (Get-ChildItem (Join-Path $BundlePath 'data\flutter_assets') -ErrorAction SilentlyContinue)) {
        throw 'data\flutter_assets is empty'
    }

    return $pluginDlls | Select-Object -ExpandProperty Name | Sort-Object
}
