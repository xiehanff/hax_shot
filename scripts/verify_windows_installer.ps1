#Requires -Version 5.1
<#
.SYNOPSIS
对已经构建好的 Windows 安装包做一次真实的「安装 → 启动 → 卸载」闭环验证（本机实测，跑完自动清理）。

.DESCRIPTION
依次做这几步，任何一步不满足：打印 `INSTALLER VERIFY: FAIL【哪一步】：原因` 并以退出码 1 结束；
全部通过打印一行可 grep 的 `INSTALLER VERIFY: PASS`：

1. 准备：定位 setup.exe（默认 `build\windows\HaxShot-<pubspec 版本>-windows-x64-setup.exe`），
   记录用户原本的 `HKCU Run\HaxShot` 值（验证结束会还回去）；
2. 静默安装到临时目录（`/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=<临时目录>`）；
3. 校验安装目录内容：必需文件 + 插件 DLL + `data\flutter_assets` + 三个 VC 运行库
   （清单来自 `scripts\windows_bundle.ps1`，与打包脚本共用同一份）；
4. 启动安装后的 `hax_shot.exe`：进程必须活着，并且日志里出现**这个 pid** 写的
   `tray_init_success`（按 pid 匹配，不受日志轮转 / 旧记录影响）；
5. 结束该进程；
6. 手动预置 `HKCU Run\HaxShot`（模拟用户开了「开机自启动」）；
7. 静默卸载（`unins000.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`）；
8. 断言：安装目录没了、开始菜单快捷方式没了、`HKCU Run\HaxShot` 没了、卸载项没了。

为什么是独立脚本，而不是给 build_windows_installer.ps1 加个 -Verify 开关：验证要能针对**已经
存在**的那个 setup.exe 跑（CI 产物、别人传过来的包），不能被“顺便重新编译一遍”盖掉；而且装一遍
再卸一遍是会对本机动手的操作，不该藏在默认构建路径里。两个脚本各自只做一件事，也更好 grep。

.EXAMPLE
pwsh scripts/build_windows_installer.ps1
pwsh scripts/verify_windows_installer.ps1
# 一条构建 + 一条验证

.EXAMPLE
pwsh scripts/verify_windows_installer.ps1 -Installer build\windows\HaxShot-1.5.0-windows-x64-setup.exe -Keep
# 验证指定安装包，失败时保留临时目录和日志
#>
[CmdletBinding()]
param(
    [string] $Installer,
    [string] $WorkDirectory,
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'
# 中文输出统一成 UTF-8：不然管道/重定向到文件时 PowerShell 会按系统代码页（GBK）写出去，
# CI 日志和 `grep INSTALLER VERIFY` 都会变成乱码。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'windows_bundle.ps1')

$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runValueName = 'HaxShot'
$startMenuShortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\HaxShot.lnk'
$logFile = Join-Path $env:LOCALAPPDATA 'hax_shot\logs\hax_shot.log'

function Invoke-Step {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $Body
    )

    Write-Host ''
    Write-Host "==> $Name"
    try {
        & $Body
    } catch {
        # 步骤名放进异常消息，最外层统一打 FAIL 并 exit 1。
        throw "【$Name】$($_.Exception.Message)"
    }
}

function Get-HaxShotInstallerAppId {
    # AppId 只有一份（packaging\hax_shot.iss 里写死的 GUID），不要在这里再抄一个：
    # 抄错了就会去查一个不存在的卸载项，验证反而“永远通过”。
    $iss = Join-Path $repoRoot 'packaging\hax_shot.iss'
    $match = Select-String -Path $iss -Pattern '^AppId=\{\{(.+?)\}\s*$' | Select-Object -First 1
    if (-not $match) { throw "packaging\hax_shot.iss 里找不到 AppId={{<GUID>}" }
    return '{' + $match.Matches.Groups[1].Value + '}'
}

$version = Get-HaxShotAppVersion -RepoRoot $repoRoot
if ($Installer) {
    $installerPath = Resolve-HaxShotPath -RepoRoot $repoRoot -Path $Installer
} else {
    $installerPath = Join-Path $repoRoot "build\windows\HaxShot-$version-windows-x64-setup.exe"
}

if ($WorkDirectory) {
    $workPath = Resolve-HaxShotPath -RepoRoot $repoRoot -Path $WorkDirectory
} else {
    $tempBase = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $workPath = Join-Path $tempBase "hax_shot_verify_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
}
$installDir = Join-Path $workPath 'install'

$appId = Get-HaxShotInstallerAppId
$uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'

function Get-HaxShotUninstallKey {
    # Inno 给每份安装建的是 <AppId>_is1 这样的键名（多份安装会往后排），所以按前缀找，
    # 不要把 '{<GUID>}' 拼死——拼错了这个函数就会“永远说没装过”。
    return @(Get-ChildItem $uninstallRoot -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like "$appId*" } |
        Select-Object -ExpandProperty PSChildName)
}

$appProcess = $null
$hadOriginalRunValue = $false
$originalRunValue = $null
$failure = $null

function Remove-HaxShotTestInstall {
    # 失败路径的兜底：把已经装进临时目录的那份卸掉，不把“半个安装”留在机器上。
    # （正常路径的卸载是第 7 步，带日志和断言。）
    $uninstaller = Join-Path $installDir 'unins000.exe'
    if (-not (Test-Path $uninstaller)) { return }
    Write-Host '失败兜底：卸载临时目录里的那份安装'
    Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -Wait | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and (Test-Path $installDir)) { Start-Sleep -Milliseconds 500 }
}

try {
    Invoke-Step '准备' {
        if (-not (Test-Path $installerPath)) {
            throw "找不到安装包：$installerPath（先跑 pwsh scripts/build_windows_installer.ps1）"
        }
        # 已经装过一份就别测了：同一个 AppId 再装一次会把用户那份的卸载信息指到临时目录，
        # 跑完变成“用户的 HaxShot 卸不掉”。这是唯一一条会污染本机的情况，宁可先拒绝。
        # PowerShell 会把只含一个元素的数组展开成标量，所以这里必须自己包 @()，
        # 否则 $existingInstalls[0] 取到的是键名的第一个字符。
        $existingInstalls = @(Get-HaxShotUninstallKey)
        if ($existingInstalls.Count -gt 0) {
            $installed = (Get-ItemProperty -Path (Join-Path $uninstallRoot $existingInstalls[0]) -ErrorAction SilentlyContinue).InstallLocation
            throw "本机已经装过一份 HaxShot（$installed，卸载项 $($existingInstalls[0])）。先卸载它再验证，否则会覆盖掉它的卸载信息。"
        }
        New-Item -ItemType Directory -Path $workPath -Force | Out-Null

        # 验证会临时改 HKCU Run，先记下用户原本的值，最后还回去。
        $existing = Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue
        if ($existing) {
            $script:hadOriginalRunValue = $true
            $script:originalRunValue = $existing.$runValueName
        }

        $size = [math]::Round((Get-Item $installerPath).Length / 1MB, 1)
        Write-Host "installer : $installerPath ($size MB)"
        Write-Host "install to: $installDir"
        if ($hadOriginalRunValue) {
            Write-Host "现有 HKCU Run\$runValueName = $originalRunValue（验证结束后恢复）"
        }
    }

    Invoke-Step '静默安装到临时目录' {
        $installLog = Join-Path $workPath 'install.log'
        $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR=`"$installDir`" /LOG=`"$installLog`""
        Write-Host "setup.exe $arguments"
        # 必须用 Start-Process -Wait：Inno Setup 的启动器会把真正的安装动作交给一个子进程，
        # 用 `& setup.exe` 会在安装还没做完时就返回（$LASTEXITCODE 那时还是空的，拿不到退出码）；
        # -Wait 会一直等到整棵进程树结束，-PassThru 才拿得到退出码。
        $proc = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "安装程序退出码 $($proc.ExitCode)（日志：$installLog）" }
        if (-not (Test-Path (Join-Path $installDir 'hax_shot.exe'))) {
            throw "安装目录里没有 hax_shot.exe：$installDir（日志：$installLog）"
        }
    }

    Invoke-Step '校验安装目录内容（必需文件 / 插件 DLL / assets / VC 运行库）' {
        $pluginDlls = Assert-HaxShotBundle -BundlePath $installDir
        $pluginDlls | ForEach-Object { Write-Host "  dll: $_" }
        Write-Host "plugin DLLs: $($pluginDlls.Count)"
        foreach ($crt in Get-HaxShotCrtFileNames) {
            if (-not (Test-Path (Join-Path $installDir $crt))) { throw "缺少 VC 运行库：$crt" }
            Write-Host "  crt: $crt"
        }
        $total = (Get-ChildItem $installDir -Recurse -File | Measure-Object -Property Length -Sum).Sum
        Write-Host "installed size: $([math]::Round($total / 1MB, 1)) MB"
    }

    Invoke-Step '启动 hax_shot.exe 并等 tray_init_success' {
        $exe = Join-Path $installDir 'hax_shot.exe'
        $proc = Start-Process -FilePath $exe -PassThru
        $script:appProcess = $proc
        Write-Host "started pid=$($proc.Id)，日志：$logFile"

        $deadline = (Get-Date).AddSeconds(60)
        $line = $null
        while ((Get-Date) -lt $deadline) {
            $proc.Refresh()
            if ($proc.HasExited) { throw "hax_shot.exe 启动后立刻退出（exit $($proc.ExitCode)）" }
            if (Test-Path $logFile) {
                # 按 pid 认自己那一行：日志会轮转，也可能有上一次运行留下的 tray_init_success。
                $line = Select-String -Path $logFile -Pattern '"event":"tray_init_success"' -SimpleMatch |
                    Where-Object { $_.Line -match "`"pid`":$($proc.Id)(,|\})" } |
                    Select-Object -First 1
                if ($line) { break }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $line) { throw "60 秒内没等到 pid=$($proc.Id) 的 tray_init_success（日志：$logFile）" }
        Write-Host $line.Line.Trim()
    }

    Invoke-Step '结束进程' {
        if (-not $appProcess) { throw '没有记录到要结束的进程' }
        if (-not $appProcess.HasExited) {
            Stop-Process -Id $appProcess.Id -Force
            $appProcess.WaitForExit(10000) | Out-Null
        }
        if (Get-Process -Id $appProcess.Id -ErrorAction SilentlyContinue) {
            throw "进程还在：pid=$($appProcess.Id)"
        }
        Write-Host "stopped pid=$($appProcess.Id)"
        $script:appProcess = $null
    }

    Invoke-Step '预置 HKCU Run\HaxShot（模拟用户开了开机自启动）' {
        if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }
        Set-ItemProperty -Path $runKey -Name $runValueName -Value "`"$(Join-Path $installDir 'hax_shot.exe')`""
        $value = (Get-ItemProperty -Path $runKey -Name $runValueName).$runValueName
        if (-not $value) { throw '预置的 Run 值读不回来' }
        Write-Host "HKCU Run\$runValueName = $value"
    }

    Invoke-Step '静默卸载' {
        $uninstaller = Join-Path $installDir 'unins000.exe'
        if (-not (Test-Path $uninstaller)) { throw "安装目录里没有 unins000.exe：$uninstaller" }
        $uninstallLog = Join-Path $workPath 'uninstall.log'
        $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$uninstallLog`""
        Write-Host "unins000.exe $arguments"
        # 同样用 Start-Process -Wait：卸载器会把自己拷到 %TEMP% 里再跑（顺便无视后面的轮询），
        # 直接调用只会拿到启动器那一下的退出码。
        $proc = Start-Process -FilePath $uninstaller -ArgumentList $arguments -Wait -PassThru
        if ($proc.ExitCode -ne 0) { throw "卸载程序退出码 $($proc.ExitCode)（日志：$uninstallLog）" }
    }

    Invoke-Step '断言卸载干净（目录 / 开始菜单快捷方式 / Run 值 / 卸载项）' {
        $deadline = (Get-Date).AddSeconds(90)
        $dirGone = $false
        $linkGone = $false
        $valueGone = $false
        $entryGone = $false
        while ((Get-Date) -lt $deadline) {
            $dirGone = -not (Test-Path $installDir)
            $linkGone = -not (Test-Path $startMenuShortcut)
            $valueGone = -not (Get-ItemProperty -Path $runKey -Name $runValueName -ErrorAction SilentlyContinue)
            $entryGone = @(Get-HaxShotUninstallKey).Count -eq 0
            if ($dirGone -and $linkGone -and $valueGone -and $entryGone) { break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $dirGone) { throw "安装目录还在：$installDir" }
        if (-not $linkGone) { throw "开始菜单快捷方式还在：$startMenuShortcut" }
        if (-not $valueGone) { throw "HKCU Run\$runValueName 还在" }
        if (-not $entryGone) { throw "卸载项还在：$uninstallRoot\$($appId)_is1" }
        Write-Host '安装目录、开始菜单快捷方式、HKCU Run\HaxShot、卸载项都已清掉'
    }
} catch {
    $failure = $_.Exception.Message
    if ($appProcess -and -not $appProcess.HasExited) {
        Stop-Process -Id $appProcess.Id -Force -ErrorAction SilentlyContinue
    }
    try { Remove-HaxShotTestInstall } catch { Write-Warning "兜底卸载失败：$($_.Exception.Message)" }
    if (-not $Keep) {
        foreach ($name in @('install.log', 'uninstall.log')) {
            $log = Join-Path $workPath $name
            if (Test-Path $log) {
                Write-Host "--- $name（最后 15 行）"
                Get-Content $log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
            }
        }
    }
} finally {
    # 恢复用户原本的自启动值，再把临时目录清掉：验证跑完机器要跟没跑过一样。
    try {
        if ($hadOriginalRunValue) {
            if (-not (Test-Path $runKey)) { New-Item -Path $runKey -Force | Out-Null }
            Set-ItemProperty -Path $runKey -Name $runValueName -Value $originalRunValue
            Write-Host "已恢复 HKCU Run\$runValueName"
        }
    } catch {
        Write-Warning "恢复 HKCU Run\$runValueName 失败：$($_.Exception.Message)"
    }
    if ($Keep) {
        Write-Host "临时目录保留在：$workPath"
    } elseif (Test-Path $workPath) {
        try {
            Remove-Item -Path $workPath -Recurse -Force
            Write-Host "已删除临时目录：$workPath"
        } catch {
            Write-Warning "临时目录删不掉，请手动清理：$workPath（$($_.Exception.Message)）"
        }
    }
}

if ($failure) {
    Write-Host ''
    Write-Host "INSTALLER VERIFY: FAIL$failure"
    exit 1
}

Write-Host ''
Write-Host "INSTALLER VERIFY: PASS（$installerPath，版本 $version）"
