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
CloseApplications=yes
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

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\micaGO"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\micaGO"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,micaGO}"; Flags: nowait postinstall skipifsilent
