; Inno Setup script for iPASide - bundles the Flutter Windows runner + the
; portable Python engine.
;
; Build (from repo root, after building the app + assembling the engine):
;   ISCC /DAppVersion=1.0.1 packaging\iPASide.iss
; Output: dist\installer\iPASide-Setup-<ver>-x64.exe

#ifndef AppVersion
  #define AppVersion "1.2.8"
#endif
#define AppName "iPASide"
#define AppPublisher "iPASide Contributors"
#define AppExe "iPASide.exe"
#define AppUrl "https://github.com/iPASide/iPASide"
; The AppId also names the Add/Remove Programs key, which the rollback code at the
; bottom of this file reads and repairs. Defined once so the two can never drift.
#define AppId "{9F1C2D3E-4B5A-46C7-8E9F-A0B1C2D3E4F5}"

[Setup]
AppId={{#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppSupportURL={#AppUrl}
; ── Look and feel: iPASide's identity, not the stock wizard ───────────────────
; dark             force the dark appearance whatever the user's Windows theme is. The
;                  installer hands over to a near-black app, and a light wizard opening
;                  it is a visible seam.
; hidebevels       the divider lines read as creases on top of the background art.
; includetitlebar  style the title bar and border too, so the window is one surface —
;                  the app's own window is chromeless for the same reason.
; Colours are the app's dark tokens: #0B0B0D canvas, indigo -> violet accent.
WizardStyle=modern dark hidebevels includetitlebar
WizardSizePercent=130
WizardBackColor=#0b0b0d
WizardBackImageFile=brand\backdrop.png
WizardImageFile=brand\panel.png
WizardSmallImageFile=brand\logo.png
; Inno 6 hides the welcome page by default in modern style, which would leave
; the branded panel showing only on the final page.
DisableWelcomePage=no
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=iPASide-Setup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
; `commandline`, not `dialog`. With `dialog` a genuinely fresh install opens on Inno's
; stock "Select Setup Install Mode" task dialog — asking all-users or just-me before the
; branded welcome page is even shown, and undoing the one-screen flow. iPASide is a
; per-user tool throughout: per-user data, a per-user scheduled task, a per-user Apple ID
; session. So there is no answer worth asking for, and /ALLUSERS still works for anyone
; who deliberately wants it.
PrivilegesRequiredOverridesAllowed=commandline
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
AppMutex=iPASide.Running.Mutex
; The wizard and Add/Remove entry use the same mark as the app itself.
SetupIconFile=..\src\iPASide.Flutter\windows\runner\resources\app_icon.ico

; ── Flow: one screen, then it installs ────────────────────────────────────────
; The stock wizard asks four questions — folder, group, tasks, confirm — about an
; install that has one sensible shape. What is left is a branded screen carrying the
; single real choice on it (the desktop shortcut), then progress, then done.
;
; No LicenseFile: MIT grants its rights without acceptance, so a click-through gate
; would be theatre. LICENSE still ships in {app}, which is what MIT actually asks for.
DisableReadyPage=yes
; Per-user, so {autopf} resolves under LocalAppData and there is nothing to decide.
; /DIR= still works for anyone who wants to override it.
DisableDirPage=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
; iPASide's own voice. Inno's default copy ("It is recommended that you close all
; other applications") tells the user nothing about what they are installing.
SetupWindowTitle=%1 Setup
WelcomeLabel1=Install iPASide
WelcomeLabel2=iPASide signs any .ipa with your own Apple ID and installs it on your iPhone or iPad, over USB or Wi-Fi — no jailbreak and no paid developer account.
; Inno appends this to the welcome text. The default ("Click Next to continue") now
; contradicts the button, which reads Install because the Ready page is gone.
ClickNext=Setup installs the app together with its self-contained signing engine. Your Apple ID is only ever sent to Apple.
WizardInstalling=Installing iPASide
InstallingLabel=Copying the app and its signing engine. The engine is a self-contained Python runtime, so this takes a few seconds.
FinishedHeadingLabel=iPASide is ready
FinishedLabel=Connect your iPhone over USB, unlock it and tap Trust. Then sign in with your Apple ID and drop an .ipa onto the window.%n%nYou also need Apple Devices (or iTunes) installed for USB access.
FinishedLabelNoIcons=Connect your iPhone over USB, unlock it and tap Trust. Then sign in with your Apple ID and drop an .ipa onto the window.
ClickFinish=Click Finish to close Setup.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; Wipe any previous engine (e.g. the old PyInstaller build) so an in-place
; upgrade never keeps stale engine files around. Also remove earlier app
; layouts - the WPF/WebView2 "web" folder, the .NET payload, and the Flutter
; "data" folder whose assets are keyed by name and would otherwise go stale.
; Safe because [Files] re-copies the whole publish\app payload.
;
; These rules run AFTER CurStepChanged(ssInstall) - verified, not assumed - so on an
; upgrade the rollback code below has already renamed {app} out of the way and every
; rule here matches nothing. They stay load-bearing for the two cases where it has
; not: a first install over a leftover folder, and an upgrade where the rename failed
; because something held a file open.
Type: filesandordirs; Name: "{app}\engine"
Type: filesandordirs; Name: "{app}\web"
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"
Type: files; Name: "{app}\*.exe"
Type: files; Name: "{app}\*.json"
Type: files; Name: "{app}\*.pdb"
Type: files; Name: "{app}\*.xml"
; .NET shipped a runtimes folder and one satellite-resource folder per language.
; Nothing in the Flutter payload recreates these, so without naming them an
; upgrade from an older iPASide leaves ~50 MB of dead files behind.
Type: filesandordirs; Name: "{app}\runtimes"
Type: filesandordirs; Name: "{app}\cs"
Type: filesandordirs; Name: "{app}\de"
Type: filesandordirs; Name: "{app}\es"
Type: filesandordirs; Name: "{app}\fr"
Type: filesandordirs; Name: "{app}\it"
Type: filesandordirs; Name: "{app}\ja"
Type: filesandordirs; Name: "{app}\ko"
Type: filesandordirs; Name: "{app}\pl"
Type: filesandordirs; Name: "{app}\pt-BR"
Type: filesandordirs; Name: "{app}\ru"
Type: filesandordirs; Name: "{app}\tr"
Type: filesandordirs; Name: "{app}\zh-Hans"
Type: filesandordirs; Name: "{app}\zh-Hant"

[Files]
Source: "..\publish\app\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "..\dist\engine\*"; DestDir: "{app}\engine"; Flags: recursesubdirs createallsubdirs ignoreversion
; Not installed — extracted to {tmp} at runtime to stand in for the native progress
; bar, which cannot be recoloured. See CreateProgressBar.
Source: "brand\bar-track.png"; Flags: dontcopy
Source: "brand\bar-fill.png"; Flags: dontcopy

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Check: never offer to start a payload that just failed to run. After a rolled-back
; upgrade the restored older iPASide is fine to launch; a damaged one is not.
; No skipifsilent: the in-app updater installs with /SILENT and the user expects the
; app to come back afterwards (the update flow closes it so Setup can swap files).
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall; Check: InstalledAppIsUsable

[UninstallDelete]
; Leftover WebView2 user-data folder from the legacy WPF/WebView2 app.
Type: filesandordirs; Name: "{localappdata}\iPASide\WebView2"

[Code]
// ── Transactional upgrade: move aside, verify, then commit ────────────────────────
// An upgrade replaces ~215 MB of app plus bundled engine in place. When that only
// half-applies - a truncated download, a crash mid-copy, a payload that shipped
// broken - the user is left with a folder that looks installed but cannot sign
// anything, and no route back. So an upgrade is staged instead of applied blind:
//
//   ssInstall      If a previous install is present, RENAME {app} aside. A rename
//                  within one volume only rewrites directory metadata, so it costs
//                  milliseconds where copying 215 MB aside would cost minutes. Inno
//                  then installs into a clean, empty {app}.
//   ssPostInstall  PROVE the new payload runs, then either discard the backup or put
//                  it back under its own name.
//
// A first install has nothing to move aside and nothing to fall back to, so it passes
// through here untouched.
//
// %LOCALAPPDATA%\iPASide - the Apple ID session, the signing certificate and private
// key, the anisette state and the sideload registry - is never part of any of this.
// Only {app} ever moves, and the only thing written under the data root is install.log.
//
// One measured limit to know before rearranging this: by the time Setup reaches
// ssPostInstall the install is already committed as far as Inno is concerned. Raising
// an exception there still exits 0 and still leaves the Add/Remove entry written, so a
// rolled-back upgrade cannot report itself through the exit code. What it can do, and
// does below, is put the working version back, say so on the final page, and leave a
// record on disk. (The in-app updater launches Setup detached and interactively, so
// the final page - not the exit code - is what a user actually sees.)

var
  // Written at ssInstall, read at ssPostInstall.
  BackupTaken: Boolean;
  // True once the backup has been dealt with for good, either discarded because the new
  // payload verified or successfully put back. Until then the backup is still the only
  // complete copy of a working iPASide, and DeinitializeSetup will restore it.
  UpgradeSettled: Boolean;
  PreviousVersion: String;
  // Non-empty once the new payload has failed to verify; drives the final page.
  FailureHeading: String;
  FailureDetail: String;
  // False only when what is left in {app} is known-broken.
  AppUsable: Boolean;

  // Welcome-page extras. The one real choice and the fine print live there so the whole
  // wizard is a single screen. They are created in InitializeWizard and positioned when
  // the page is first shown, by which point the form has its final DPI-scaled layout.
  DesktopIconCheck: TNewCheckBox;
  Highlights: TNewStaticText;
  FinePrint: TNewStaticText;
  // Stand-ins for the native progress bar.
  BarTrack: TBitmapImage;
  BarFill: TBitmapImage;

// ── Brand-coloured progress bar ───────────────────────────────────────────────
// TNewProgressBar exposes no colour property, and the active style paints it the stock
// green, which reads as a different product against this canvas. So the native bar is
// hidden and two stretched images stand in: a dark track and an indigo -> violet fill
// whose width follows real progress. Images rather than coloured panels, because a VCL
// style overrides control colours set from Pascal but cannot restyle a bitmap.
procedure CreateProgressBar;
begin
  ExtractTemporaryFile('bar-track.png');
  ExtractTemporaryFile('bar-fill.png');

  BarTrack := TBitmapImage.Create(WizardForm);
  BarTrack.Parent := WizardForm.InstallingPage;
  BarTrack.Stretch := True;
  BarTrack.PngImage.LoadFromFile(ExpandConstant('{tmp}\bar-track.png'));
  BarTrack.Visible := False;

  BarFill := TBitmapImage.Create(WizardForm);
  BarFill.Parent := WizardForm.InstallingPage;
  BarFill.Stretch := True;
  BarFill.PngImage.LoadFromFile(ExpandConstant('{tmp}\bar-fill.png'));
  BarFill.Visible := False;
end;

// Lay the stand-in exactly over the native bar, and hide the original.
procedure ShowProgressBar;
begin
  WizardForm.ProgressGauge.Visible := False;

  BarTrack.Left := WizardForm.ProgressGauge.Left;
  BarTrack.Top := WizardForm.ProgressGauge.Top;
  BarTrack.Width := WizardForm.ProgressGauge.Width;
  BarTrack.Height := WizardForm.ProgressGauge.Height;
  BarTrack.Visible := True;

  BarFill.Left := BarTrack.Left;
  BarFill.Top := BarTrack.Top;
  BarFill.Height := BarTrack.Height;
  BarFill.Width := 0;
  BarFill.Visible := True;
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if (BarFill <> nil) and BarFill.Visible and (MaxProgress > 0) then
    BarFill.Width := (BarTrack.Width * CurProgress) div MaxProgress;
end;

procedure InitializeWizard;
begin
  CreateProgressBar;

  Highlights := TNewStaticText.Create(WizardForm);
  Highlights.Parent := WizardForm.WelcomePage;
  Highlights.WordWrap := False;
  Highlights.Caption :=
    '•   Sign and install any .ipa with your own Apple ID' + #13#10 +
    '•   Inject .deb or .dylib tweaks while you do it' + #13#10 +
    '•   Re-signs your apps before their 7 days run out';

  DesktopIconCheck := TNewCheckBox.Create(WizardForm);
  DesktopIconCheck.Parent := WizardForm.WelcomePage;
  DesktopIconCheck.Caption := 'Create a desktop shortcut';

  FinePrint := TNewStaticText.Create(WizardForm);
  FinePrint.Parent := WizardForm.WelcomePage;
  FinePrint.WordWrap := True;
end;

function AppDir: String;
begin
  Result := ExpandConstant('{app}');
end;

function BackupDir: String;
begin
  // A sibling of {app}, so the backup is guaranteed to be on the same volume and the
  // move stays a rename. Anywhere else - {tmp}, a data folder on another drive - risks
  // a cross-volume move, which Windows quietly turns into a full byte-for-byte copy.
  Result := AppDir + '.rollback';
end;

function InstallLogPath: String;
begin
  // Deliberately not under {app}: that directory is renamed away, replaced and
  // sometimes deleted while this log is being written. The app's own data root already
  // keeps autorefresh.log, and Setup only ever APPENDS here - nothing under that root
  // is created, moved or deleted by an install, a rollback or an uninstall.
  Result := ExpandConstant('{localappdata}\iPASide\install.log');
end;

procedure LogInstall(Msg: String);
var
  Existing: AnsiString;
  Line: String;
begin
  Log(Msg);  // also into Setup's own /LOG file, when one was asked for
  Line := '[' + GetDateTimeString('yyyy-mm-dd hh:nn:ss', '-', ':') + '] {#AppVersion}: ' + Msg;
  ForceDirectories(ExpandConstant('{localappdata}\iPASide'));
  if LoadStringFromFile(InstallLogPath, Existing) then
    SaveStringToFile(InstallLogPath, Existing + Line + #13#10, False)
  else
    SaveStringToFile(InstallLogPath, Line + #13#10, False);
end;

function UninstallKey: String;
begin
  // Per-user install, so Inno keeps the Add/Remove entry under HKCU.
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#AppId}_is1';
end;

// Erasing a directory tree from a path that came out of a constant deserves a positive
// identification first: {app} can be pointed anywhere with /DIR=, and "the folder
// exists" is not the same as "this folder is ours to delete".
function LooksLikeOurInstall(Dir: String): Boolean;
begin
  Result := (Length(Dir) > 3) and DirExists(Dir)
        and (FileExists(AddBackslash(Dir) + '{#AppExe}')
          or FileExists(AddBackslash(Dir) + 'unins000.exe'));
end;

// "The exe is there" is not proof of a working install. The engine is ~10,000 files of
// Python and native code, and the failure guarded against here is precisely the one
// where everything is present but something is truncated. `ipaside_engine version`
// imports the whole engine package on its way to printing one line - pymobiledevice3,
// anisette's unicorn native library, cryptography, Pillow - so exit code 0 means the
// payload actually runs, not merely that it arrived.
function NewInstallAnswers: Boolean;
var
  Engine, Probe, Detail: String;
  Output: AnsiString;
  ResultCode: Integer;
begin
  Result := False;

  if not FileExists(AddBackslash(AppDir) + '{#AppExe}') then
  begin
    LogInstall('verify: {#AppExe} is missing from ' + AppDir);
    Exit;
  end;

  Engine := AddBackslash(AppDir) + 'engine\python\python.exe';
  if not FileExists(Engine) then
  begin
    LogInstall('verify: the bundled engine is missing (' + Engine + ')');
    Exit;
  end;

  // Routed through cmd.exe with the output redirected to a file: Setup is a GUI process
  // with no console for the child to inherit, and capturing the text means a failure
  // leaves the real Python traceback in the log rather than a bare exit code.
  Probe := ExpandConstant('{tmp}\engine-verify.txt');
  DeleteFile(Probe);
  if not Exec(ExpandConstant('{cmd}'),
              '/c ""' + Engine + '" -m ipaside_engine version > "' + Probe + '" 2>&1"',
              AppDir, SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    LogInstall('verify: the engine could not be started at all');
    Exit;
  end;

  if LoadStringFromFile(Probe, Output) then
    Detail := Trim(String(Output))
  else
    Detail := '(no output)';

  Result := ResultCode = 0;
  if Result then
    LogInstall('verify: engine answered - ' + Detail)
  else
    LogInstall('verify: engine exited ' + IntToStr(ResultCode) + ' - ' + Detail);
end;

procedure StageUpgrade;
begin
  // No iPASide.exe means there is nothing to fall back to: a first install, or a
  // directory some earlier run left half-written. Both install straight in, and the
  // [InstallDelete] rules clear out whatever old layout is lying there.
  if not FileExists(AddBackslash(AppDir) + '{#AppExe}') then
  begin
    LogInstall('first install into ' + AppDir);
    Exit;
  end;

  // Read while it is still true: Inno rewrites DisplayVersion during the install, so
  // from here on the registry claims the new version even if the files on disk end up
  // being the old ones again.
  RegQueryStringValue(HKEY_CURRENT_USER, UninstallKey, 'DisplayVersion', PreviousVersion);

  // A backup left behind by a run that died between the move and the verify. The
  // payload about to be copied supersedes it, so now it is only in the way.
  if LooksLikeOurInstall(BackupDir) then
  begin
    LogInstall('discarding a rollback backup left behind by an earlier run');
    DelTree(BackupDir, True, True, True);
  end;

  // AppMutex has already turned the install away if iPASide itself is running, but a
  // resident engine process, an antivirus scan or an open Explorer window can still
  // hold a handle, and then this fails. A missing safety net is not worth failing an
  // otherwise fine upgrade over, so record it and continue without one.
  if RenameFile(AppDir, BackupDir) then
  begin
    BackupTaken := True;
    LogInstall('upgrade from version ' + PreviousVersion + ': previous install moved to '
      + BackupDir);
  end
  else
    LogInstall('upgrade from version ' + PreviousVersion + ': could not move the previous'
      + ' install aside (a file is in use) - installing in place, WITHOUT rollback'
      + ' protection');
end;

// Put the moved-aside install back under its own name. Shared by the two ways an upgrade
// can go wrong: the new payload failing to verify, and Setup never getting that far.
function RestorePreviousInstall: Boolean;
begin
  // Order matters: RenameFile cannot land on a directory that already exists, so the new
  // (or half-written) payload has to be gone before the backup can take its name back.
  if LooksLikeOurInstall(AppDir) then
    DelTree(AppDir, True, True, True);

  Result := RenameFile(BackupDir, AppDir);
  if Result then
  begin
    UpgradeSettled := True;
    // The one Add/Remove value that would otherwise lie. Everything else in that entry
    // - install location, uninstall command, icon - still describes the restored files.
    if PreviousVersion <> '' then
      RegWriteStringValue(HKEY_CURRENT_USER, UninstallKey, 'DisplayVersion', PreviousVersion);
  end;
end;

procedure RollBackUpgrade;
begin
  WizardForm.StatusLabel.Caption := 'Restoring the previous version of iPASide...';

  if RestorePreviousInstall then
  begin
    LogInstall('ROLLED BACK: version ' + PreviousVersion + ' restored to ' + AppDir);
    FailureHeading := 'The update was rolled back';
    // Kept to about five lines: this same text goes on the Finished page, whose label has
    // a fixed height, and anything longer is silently clipped there (seen while testing).
    FailureDetail :=
      'iPASide {#AppVersion} was installed, but its signing engine did not start, so Setup'
      + ' put your previous version back - iPASide still works. Your Apple ID session and'
      + ' signing material were not touched.' + #13#10#13#10
      + 'Details: ' + InstallLogPath;
  end
  else
  begin
    // Both trees still exist, so nothing is lost - but {app} is empty and only the user
    // can free whatever is holding it. Name the folder so the recovery is a rename.
    // UpgradeSettled stays False on purpose: DeinitializeSetup gets one more attempt
    // once Setup has let go of everything it had open.
    AppUsable := False;
    LogInstall('ROLLBACK FAILED: ' + BackupDir + ' could not be moved back to ' + AppDir);
    FailureHeading := 'iPASide is not installed';
    FailureDetail :=
      'The new files were removed, but the previous version could not be moved back -'
      + ' something on this PC is holding that folder open. Nothing was lost; it is intact'
      + ' at' + #13#10 + BackupDir + #13#10#13#10
      + 'Restart Windows and run Setup again.';
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
  begin
    BackupTaken := False;
    UpgradeSettled := False;
    AppUsable := True;
    PreviousVersion := '';
    FailureHeading := '';
    FailureDetail := '';
    StageUpgrade;
  end;

  if CurStep = ssPostInstall then
  begin
    if NewInstallAnswers then
    begin
      // Committed. From here the backup must never come back, whatever happens next.
      UpgradeSettled := True;
      if BackupTaken then
      begin
        // Leaving 200-odd MB of superseded payload behind in %LOCALAPPDATA% would
        // undo the point of keeping the install per-user and small.
        WizardForm.StatusLabel.Caption := 'Removing the previous version...';
        DelTree(BackupDir, True, True, True);
        LogInstall('new install verified; rollback backup discarded');
      end
      else
        LogInstall('install verified');
      Exit;
    end;

    if BackupTaken then
      RollBackUpgrade
    else
    begin
      // Nothing to go back to, so the wizard must not claim success either.
      AppUsable := False;
      LogInstall('install did NOT verify and there was no previous version to restore');
      FailureHeading := 'iPASide is not ready';
      FailureDetail :=
        'iPASide was installed, but its signing engine did not start, and there was no'
        + ' previous version to restore. Running Setup again usually fixes a damaged'
        + ' download.' + #13#10#13#10
        + 'Details: ' + InstallLogPath;
    end;

    // Suppressible on purpose: a scripted or silent install must not hang on a dialog,
    // and install.log is the record that survives either way.
    SuppressibleMsgBox(FailureHeading + #13#10#13#10 + FailureDetail,
      mbCriticalError, MB_OK, IDOK);
  end;
end;

function InstalledAppIsUsable: Boolean;
begin
  Result := AppUsable;
end;

procedure DeinitializeSetup;
begin
  // Last line of defence, and not a theoretical one: ssPostInstall never runs at all if
  // the user hits Cancel during the copy or Setup dies partway through. Observed while
  // testing this - cancelling mid-copy left a 110 MB half-written {app} next to the
  // intact 320 MB backup, i.e. precisely the broken install this section exists to
  // prevent. DeinitializeSetup always runs, so the recovery belongs here as well.
  if UpgradeSettled or not BackupTaken or not DirExists(BackupDir) then
    Exit;

  if RestorePreviousInstall then
    LogInstall('setup did not finish (cancelled or interrupted); version '
      + PreviousVersion + ' restored from the backup')
  else
    LogInstall('setup did not finish and the previous version could NOT be moved back -'
      + ' it is still intact at ' + BackupDir);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  // The tasks page is skipped, so the welcome-page checkbox is the only thing that can
  // select the task, and it has to be applied before the install reads it.
  if CurPageID = wpWelcome then
  begin
    if DesktopIconCheck.Checked then
      WizardSelectTasks('desktopicon')
    else
      WizardSelectTasks('!desktopicon');
  end;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  // The only task has a checkbox on the welcome page already; its own page would be a
  // second click asking the same question.
  Result := PageID = wpSelectTasks;
end;

procedure CurPageChanged(CurPageID: Integer);
var
  HighlightsTop, HighlightsMaxTop: Integer;
begin
  if CurPageID = wpWelcome then
  begin
    // Everything below the intro copy is anchored to the BOTTOM of the page. The copy
    // above varies in height with DPI, font scaling and translation, so measuring
    // downward from it eventually collides with it — and anchoring the fine print up
    // from the bottom is what stops its last line being clipped off the page edge.
    Highlights.Left := WizardForm.WelcomeLabel2.Left;
    Highlights.Width := WizardForm.WelcomeLabel2.Width;
    // Sit directly under the intro copy, which means measuring it: AutoSize collapses
    // the label to its wrapped text height, where Inno otherwise leaves it stretched
    // down the page. Clamped, so if that copy ever grows the list stops above the
    // checkbox instead of overlapping it.
    WizardForm.WelcomeLabel2.AutoSize := True;
    HighlightsTop := WizardForm.WelcomeLabel2.Top + WizardForm.WelcomeLabel2.Height + ScaleY(20);
    HighlightsMaxTop := WizardForm.WelcomePage.ClientHeight - ScaleY(152);
    if HighlightsTop > HighlightsMaxTop then
      HighlightsTop := HighlightsMaxTop;
    Highlights.Top := HighlightsTop;

    DesktopIconCheck.Left := WizardForm.WelcomeLabel2.Left;
    DesktopIconCheck.Width := WizardForm.WelcomeLabel2.Width;
    DesktopIconCheck.Height := ScaleY(20);
    DesktopIconCheck.Top := WizardForm.WelcomePage.ClientHeight - ScaleY(76);
    // Reflect /TASKS= from the command line rather than overwriting it.
    DesktopIconCheck.Checked := WizardIsTaskSelected('desktopicon');

    FinePrint.Left := WizardForm.WelcomeLabel2.Left;
    FinePrint.Width := WizardForm.WelcomeLabel2.Width;
    FinePrint.Height := ScaleY(46);
    FinePrint.Top := WizardForm.WelcomePage.ClientHeight - ScaleY(48);
    // WizardDirValue, NOT ExpandConstant('{app}'): {app} is not initialised while the
    // welcome page is showing, and expanding it there is a hard runtime error.
    FinePrint.Caption :=
      'Free and open source (MIT). No account, no telemetry, no iPASide server.' + #13#10 +
      'Installs to ' + WizardDirValue;

    // There is no Ready page to press Install on any more, so this is that button.
    WizardForm.NextButton.Caption := SetupMessage(msgButtonInstall);
  end;

  if CurPageID = wpInstalling then
    ShowProgressBar;

  // The [Messages] copy for this page promises a working iPASide and tells the user to
  // plug in an iPhone. When the payload failed to verify that is simply untrue, and
  // this page is the only place most people will ever look.
  if (CurPageID = wpFinished) and (FailureHeading <> '') then
  begin
    WizardForm.FinishedHeadingLabel.Caption := FailureHeading;
    WizardForm.FinishedLabel.Caption := FailureDetail;
  end;
end;
