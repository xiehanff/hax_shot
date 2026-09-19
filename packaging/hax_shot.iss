; HaxShot 的 Windows 安装包（Inno Setup 6）。
;
; 只做一件事：把**已经构建好**的 Release bundle 装进当前用户目录。不构建、不签名、不联网。
; 版本号 / bundle 目录 / 输出目录一律从命令行传入，这里不写死：
;
;   ISCC.exe /DAppVersion=1.5.0 /DSourceDir=<Release 目录> /DOutputDir=<输出目录> packaging\hax_shot.iss
;
; 实际调用方是 scripts/build_windows_installer.ps1（它先让 windows_bundle.ps1 补上
; app-local VC 运行库、校验 bundle，再来编译这个脚本）。见 docs/packaging.md 的 Windows 一节。
;
; 设计要点（都是踩过或差一点踩到的坑）：
;
; - **每用户安装、不要 UAC**（PrivilegesRequired=lowest）：默认装到
;   %LOCALAPPDATA%\Programs\HaxShot。HaxShot 是托盘常驻程序，不上服务、不写 HKLM，
;   全局快捷键和自启动都只动当前用户，装进 Program Files 只会白白多一次 UAC。
; - **AppId 是一次性生成后写死的 GUID**：升级识别靠它（前一个版本用同一个 AppId 才能被
;   覆盖安装）。每次构建都换一个 GUID 的话，控制面板里会攒下一堆卸不掉的旧条目。
; - **CloseApplications=force**：HaxShot 装完就会被正在运行的实例占着 exe 和 DLL，升级时
;   不先关掉它就会“文件被占用 → 升级失败或半新半旧”。这里交给 Windows Restart Manager
;   处理，不要自己 taskkill（Restart Manager 至少会先发 WM_CLOSE）。
;   必须是 `force`，不能只写 `yes`（默认值）：托盘宿主没有可见主窗口，也不会响应
;   WM_CLOSE 退出，Restart Manager 的“温柔关闭”拿它没办法——实测（本机 6.7.3）
;   `/VERYSILENT` 升级时 setup 会报“Some applications could not be shut down”
;   然后以退出码 5 中止。加 `force` 之后静默升级才会真的成功。
;   代价：升级时如果有未完成的框选浮层，用户会丢掉那一次选区（可接受，设置会立即存盘）。
; - **RestartApplications=no**：被关掉的实例不自动重启。托盘程序重启一个“用户自己没要的”
;   进程很意外（静默升级时尤其），而且 [Run] 里已经有“运行 HaxShot”可选。
; - **卸载要清掉自启动值**：见 [Code] 里的说明（为什么不用 [Registry] 的 uninsdeletevalue）。

#ifndef AppVersion
  #error 缺少 AppVersion 定义：用 /DAppVersion=<版本> 传入（版本只来自 pubspec.yaml）
#endif
#ifndef SourceDir
  #error 缺少 SourceDir 定义：用 /DSourceDir=<Release bundle 目录> 传入
#endif
#ifndef OutputDir
  #error 缺少 OutputDir 定义：用 /DOutputDir=<输出目录> 传入
#endif

[Setup]
AppId={{A77FFE11-1999-4C5D-A1B5-E4B83FC25650}
AppName=HaxShot
AppVersion={#AppVersion}
AppVerName=HaxShot {#AppVersion}
AppPublisher=xiehanff
AppPublisherURL=https://github.com/xiehanff/hax_shot
AppSupportURL=https://github.com/xiehanff/hax_shot/issues
AppUpdatesURL=https://github.com/xiehanff/hax_shot/releases
VersionInfoVersion={#AppVersion}
VersionInfoProductName=HaxShot
VersionInfoCompany=xiehanff
VersionInfoDescription=HaxShot {#AppVersion} 安装程序
DefaultDirName={autopf}\HaxShot
DefaultGroupName=HaxShot
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayName=HaxShot
UninstallDisplayIcon={app}\hax_shot.exe
OutputDir={#OutputDir}
OutputBaseFilename=HaxShot-{#AppVersion}-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
CloseApplications=force
RestartApplications=no
AllowNoIcons=yes

[Languages]
Name: "chinese"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

; 整个 Release bundle（exe、hax_shot_native.dll、flutter_windows.dll、全部插件 DLL、
; data\app.so、data\icudtl.dat、data\flutter_assets\**）+ 打包脚本补进来的三个 VC 运行库。
; 清单和完整性检查在 scripts/windows_bundle.ps1：这里照单全收，缺文件的判定留给调用方。
[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; 开始菜单快捷方式是必需的，桌面快捷方式默认不勾（托盘程序，桌面图标没什么用）。
[Icons]
Name: "{autoprograms}\HaxShot"; Filename: "{app}\hax_shot.exe"
Name: "{autodesktop}\HaxShot"; Filename: "{app}\hax_shot.exe"; Tasks: desktopicon

; 装完可以让用户直接启动；静默安装（/SILENT、/VERYSILENT）跳过，不要在 CI 里弹出托盘程序。
[Run]
Filename: "{app}\hax_shot.exe"; Description: "{cm:LaunchProgram,HaxShot}"; Flags: nowait postinstall skipifsilent

[Code]
const
  HaxShotRunKey = 'Software\Microsoft\Windows\CurrentVersion\Run';
  HaxShotRunValue = 'HaxShot';

// 卸载时删掉自己的开机自启动值（HKCU Run 下的 `HaxShot`，只删这一个值名，不动 Run 下别的项）。
//
// 为什么不在 [Registry] 里写 uninsdeletevalue：那种写法在**安装**时也会处理一次这个值，
// 于是“装个新版本”就会把用户在设置里打开的「开机自启动」悄悄关掉，用户只能自己再打开一次。
// 这里只在卸载那一步删，值本来不存在时 RegDeleteValue 返回 False，不是错误。
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RegDeleteValue(HKEY_CURRENT_USER, HaxShotRunKey, HaxShotRunValue);
end;

// Inno Setup 自带的 Default.isl 只有英文，简体中文不在官方发行版里（要另外下载第三方的 .isl）。
// 这里直接把向导要用的文案覆盖成中文，顺带保证安装包不依赖任何外部翻译文件。
[Messages]
SetupAppTitle=安装程序
SetupWindowTitle=安装 %1
UninstallAppTitle=卸载
UninstallAppFullTitle=卸载 %1
InformationTitle=提示
ConfirmTitle=确认
ErrorTitle=错误
SetupAlreadyRunning=安装程序已经在运行。
SetupAppRunningError=检测到 %1 正在运行。%n%n请先从托盘图标退出它，再点「确定」继续；或点「取消」退出安装。
UninstallAppRunningError=检测到 %1 正在运行。%n%n请先从托盘图标退出它，再点「确定」继续；或点「取消」退出卸载。
ErrorCreatingDir=无法创建目录「%1」
ExitSetupTitle=退出安装
ExitSetupMessage=安装还没有完成。现在退出的话，HaxShot 不会被安装。%n%n要退出安装程序吗？
AboutSetupMenuItem=关于安装程序(&A)...
ButtonBack=< 上一步(&B)
ButtonNext=下一步(&N) >
ButtonInstall=安装(&I)
ButtonOK=确定
ButtonCancel=取消
ButtonYes=是(&Y)
ButtonNo=否(&N)
ButtonFinish=完成(&F)
ButtonBrowse=浏览(&B)...
ButtonNewFolder=新建文件夹(&M)
ClickNext=点「下一步」继续，或点「取消」退出安装程序。
WelcomeLabel1=欢迎使用 [name] 安装向导
WelcomeLabel2=将在这台电脑上安装 [name/ver]。%n%nHaxShot 是托盘常驻的截图工具：装完不会出现主窗口，图标在任务栏右下角的托盘里（Windows 11 可能被收进「^」溢出菜单）。%n%n继续之前建议先退出正在运行的 HaxShot。
SelectDirDesc=[name] 装到哪个文件夹？
SelectDirLabel3=安装程序会把 [name] 装进下面这个文件夹。
SelectDirBrowseLabel=点「下一步」继续；想换文件夹就点「浏览」。
CannotInstallToNetworkDrive=不能安装到网络驱动器。
CannotInstallToUNCPath=不能安装到 UNC 路径。
DirExistsTitle=文件夹已存在
DirExists=文件夹：%n%n%1%n%n已经存在。要把 [name] 装进这个文件夹吗？
DiskSpaceMBLabel=至少需要 [mb] MB 可用空间。
WizardSelectTasks=选择附加任务
SelectTasksDesc=还要顺便做哪些事？
SelectTasksLabel2=选择安装 [name] 时要一并完成的任务，然后点「下一步」。
WizardReady=准备安装
ReadyLabel1=安装程序已经准备好，可以开始安装 [name] 了。
ReadyLabel2a=点「安装」开始；想改设置就点「上一步」。
ReadyLabel2b=点「安装」开始。
ReadyMemoDir=安装位置：
ReadyMemoGroup=开始菜单文件夹：
ReadyMemoTasks=附加任务：
WizardPreparing=准备安装
PreparingDesc=安装程序正在准备安装 [name]。
ApplicationsFound=下面这些程序正在使用安装程序要更新的文件。建议让安装程序自动关闭它们。
ApplicationsFound2=下面这些程序正在使用安装程序要更新的文件。建议让安装程序自动关闭它们，安装结束后安装程序会尝试重新打开。
CloseApplications=自动关闭这些程序(&A)
DontCloseApplications=不要关闭这些程序(&D)
ErrorCloseApplications=安装程序没能自动关掉这些程序。建议先手动退出正在使用这些文件的程序，再继续安装。
WizardInstalling=正在安装
InstallingLabel=正在安装 [name]，请稍候。
FinishedHeadingLabel=[name] 安装完成
FinishedLabel=[name] 已经装好了。它是托盘常驻程序，启动后不会出现主窗口，图标在任务栏右下角的托盘里。
ClickFinish=点「完成」退出安装程序。
RunEntryExec=运行 %1
StatusClosingApplications=正在关闭程序...
StatusCreateDirs=正在创建文件夹...
StatusExtractFiles=正在解压文件...
StatusCreateIcons=正在创建快捷方式...
StatusSavingUninstall=正在保存卸载信息...
StatusRunProgram=正在收尾...
ConfirmUninstall=确定要卸载 %1 吗？
UninstallStatusLabel=正在卸载 %1，请稍候。
UninstalledAll=%1 已卸载。
UninstalledMost=%1 卸载完成。%n%n有少数项没能删除，需要手动清理。
UninstalledAndNeedsRestart=要完成 %1 的卸载，需要先重启电脑。%n%n现在重启吗？
ShutdownBlockReasonInstallingApp=正在安装 %1。
ShutdownBlockReasonUninstallingApp=正在卸载 %1。
UninstallDisplayNameMarkCurrentUser=当前用户

; 下面三个是 Inno Setup 的“自定义消息”（Default.isl 里在 [CustomMessages] 段），
; 放在 [Messages] 里会被当成未知消息名并忽略（构建时会打 Warning）。
[CustomMessages]
AdditionalIcons=附加快捷方式：
CreateDesktopIcon=创建桌面快捷方式(&D)
LaunchProgram=运行 %1
