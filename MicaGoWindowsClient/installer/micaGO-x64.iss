#ifndef SourceDir
  #error SourceDir must point to the staged x64 release directory.
#endif
#ifndef OutputDir
  #error OutputDir must point to the artifacts directory.
#endif
#ifndef AppVersion
  #error AppVersion must be supplied by build-installer-x64.ps1.
#endif

#define AppName "micaGO"
#define AppExeName "micaGO.App.exe"

[Setup]
AppId={{7B86472B-ACD1-4D93-9C64-4C29D9E0FB2E}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=micaGO
AppPublisherURL=https://github.com/cinmou/micaGO
AppSupportURL=https://github.com/cinmou/micaGO/issues
AppUpdatesURL=https://github.com/cinmou/micaGO/releases
DefaultDirName={autopf}\micaGO
DefaultGroupName=micaGO
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=micaGO-Setup-x64
SetupIconFile=..\src\micaGO.App\Assets\micaGO.ico
UninstallDisplayIcon={app}\{#AppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
AppMutex=micaGO.App.Running
RestartApplications=no
SetupLogging=yes
VersionInfoCompany=micaGO
VersionInfoDescription=micaGO Setup
VersionInfoProductName=micaGO
VersionInfoProductVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
Name: "chinesetraditional"; MessagesFile: "compiler:Languages\ChineseTraditional.isl"

[CustomMessages]
english.ExitRunningApp=Exit micaGO before installing. If micaGO is in the system tray, right-click its icon and choose Exit. Then click Install again.
chinesesimplified.ExitRunningApp=请先退出 micaGO。如果应用在系统托盘中，请右键点击图标并选择退出，然后再次点击安装。
chinesetraditional.ExitRunningApp=請先結束 micaGO。如果應用程式在系統匣中，請以滑鼠右鍵點選圖示並選擇結束，然後再次點選安裝。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\micaGO"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\micaGO"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,micaGO}"; Flags: nowait postinstall skipifsilent

[Code]
function InstalledAppIsRunning: Boolean;
var
  Locator, Wmi, Processes, Process: Variant;
  AppPath, ProcessPath: String;
  Index: Integer;
begin
  Result := False;
  AppPath := ExpandConstant('{app}\{#AppExeName}');
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Wmi := Locator.ConnectServer('.', 'root\CIMV2');
    Processes := Wmi.ExecQuery('SELECT ExecutablePath FROM Win32_Process WHERE Name = ''{#AppExeName}''');
    for Index := 0 to Processes.Count - 1 do
    begin
      Process := Processes.ItemIndex(Index);
      ProcessPath := '';
      if not VarIsNull(Process.ExecutablePath) then
        ProcessPath := Process.ExecutablePath;
      // WMI can report the process name without exposing its path.
      if (CompareText(ProcessPath, AppPath) = 0) or
         ((ProcessPath = '') and FileExists(AppPath)) then
      begin
        Result := True;
        Exit;
      end;
    end;
  except
    Log('Could not check for a running micaGO process: ' + GetExceptionMessage);
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if (CurPageID = wpReady) and InstalledAppIsRunning then
  begin
    Log('micaGO is still running from the selected installation directory.');
    SuppressibleMsgBox(CustomMessage('ExitRunningApp'), mbInformation, MB_OK, IDOK);
    Result := False;
  end;
end;
