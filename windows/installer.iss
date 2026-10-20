#ifndef OutputDir
  #define OutputDir "..\..\..\outputs"
#endif
#define AppVersion "2.8.4.51"

[Setup]
AppId={{2670CB6A-08AD-4B01-8A9E-AE241ED4B38A}
AppName=NAKU Player
AppVersion={#AppVersion}
AppPublisher=NakuTop
AppPublisherURL=https://github.com/NakuTop/NAKU-Player
AppSupportURL=https://github.com/NakuTop/NAKU-Player/issues
DefaultDirName={localappdata}\Programs\NAKU Player
DefaultGroupName=NAKU Player
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=NAKUPlayer-{#AppVersion}-Windows-x64-Setup
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\NAKUPlayer.exe
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb,*.lib,*.exp"
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\NAKU Player"; Filename: "{app}\NAKUPlayer.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\NAKU Player"; Filename: "{app}\NAKUPlayer.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\NAKUPlayer.exe"; Description: "Launch NAKU Player"; Flags: nowait postinstall skipifsilent
