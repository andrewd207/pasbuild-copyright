{
  pasbuild-copyright - A plugin for pasbuild to help administer copyright
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD 3-Clause License. See LICENSE file for details.
}

program main;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, StrUtils, DateUtils,
  UGitUtils, UBlacklist, UCopyrightScanner, ULicenseDetect
  {$IFDEF UNIX}
  , BaseUnix
  {$ENDIF}
  ;

const

  {$IFDEF WINDOWS}
  CDefaultInstalledFolder = 'C:\\Users\\$user\\.pasbuild\\';
  {$ELSEIF Defined(MACOSX)}
  CDefaultInstalledFolder = '/Users/$user/.pasbuild//';
  {$ELSE}
  CDefaultInstalledFolder = '/home/$user/.pasbuild/';
  {$ENDIF}

type
  TMode = (pmUnknown, pmCheck, pmFix);

var
  GCurrentYear: Integer;

function GetExeBaseName: string;
begin
  Result := ExtractFileName(ParamStr(0));
  Result := ChangeFileExt(Result, '');
end;

function DetectMode: TMode;
var
  N: string;
begin
  N := LowerCase(GetExeBaseName);
  if Pos('copyright-check', N) > 0 then
    Exit(pmCheck);
  if Pos('copyright-fix', N) > 0 then
    Exit(pmFix);
  Result := pmUnknown;
end;

function GetEnvSmart(const AName: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := GetEnvironmentVariable(UpperCase(AName));
end;

function ResolveInstalledFolder: string;
var
  S, UserName: string;
begin
  S := IncludeTrailingPathDelimiter(CDefaultInstalledFolder) + 'plugins' + PathDelim;
  UserName := GetEnvSmart('user');
  if UserName = '' then
    UserName := GetEnvSmart('username');
  if UserName = '' then
    UserName := GetEnvSmart('logname');
  if UserName = '' then
    UserName := GetEnvSmart('home');

  if Pos(PathDelim, UserName) > 0 then
    UserName := ExtractFileName(ExcludeTrailingPathDelimiter(UserName));

  Result := StringReplace(S, '$user', UserName, [rfReplaceAll, rfIgnoreCase]);
end;

procedure EnsureDir(const ADir: string);
begin
  if not DirectoryExists(ADir) then
    if not ForceDirectories(ADir) then
      raise Exception.Create('Failed to create directory: ' + ADir);
end;

function CopyFileSimple(const SrcName, DstName: string): Boolean;
var
  SrcStream, DstStream: TFileStream;
begin
  Result := False;
  SrcStream := nil;
  DstStream := nil;
  try
    SrcStream := TFileStream.Create(SrcName, fmOpenRead or fmShareDenyWrite);
    DstStream := TFileStream.Create(DstName, fmCreate);
    DstStream.CopyFrom(SrcStream, 0);
    Result := True;
  finally
    SrcStream.Free;
    DstStream.Free;
  end;
  {$IFDEF UNIX}
  if Result then
    fpChmod(DstName, &755);
  {$ENDIF}
end;

procedure InstallPlugin;
var
  InstallDir, SrcExe, DstCheck, DstFix: string;
begin
  InstallDir := ResolveInstalledFolder;
  EnsureDir(InstallDir);

  SrcExe := ExpandFileName(ParamStr(0));
  DstCheck := IncludeTrailingPathDelimiter(InstallDir) + 'pasbuild-copyright-check';
  DstFix := IncludeTrailingPathDelimiter(InstallDir) + 'pasbuild-copyright-fix';

  if not CopyFileSimple(SrcExe, DstCheck) then
    raise Exception.Create('Failed to copy plugin to: ' + DstCheck);

  if not CopyFileSimple(SrcExe, DstFix) then
    raise Exception.Create('Failed to copy plugin to: ' + DstFix);

  WriteLn('[INFO] Installed ', DstCheck);
  WriteLn('[INFO] Installed ', DstFix);
end;

{ Resolves which license applies to AFilePath.
  Prefers a LICENSE file found directly in the file's own directory.
  Falls back to ARootLicense when no directory-specific file exists.
  Sets AHasDirLicense when the directory has its own license file distinct
  from the root's, so callers can decide whether to emit a mismatch warning. }
procedure ResolveFileLicense(const AFilePath: string;
                              const ARootLicFile: string;
                              ARootLicense: TLicenseType;
                              out AEffectiveLicense: TLicenseType;
                              out AHasDirLicense: Boolean);
var
  FileDir, DirLicFile: string;
  DirLic: TLicenseType;
begin
  FileDir := ExtractFileDir(AFilePath);
  if FileDir = '' then
    FileDir := '.';

  DirLicFile := FindLicenseFile(FileDir);

  AHasDirLicense := (DirLicFile <> '') and
                    (ExpandFileName(DirLicFile) <> ExpandFileName(ARootLicFile));

  if AHasDirLicense then
  begin
    DirLic := DetectLicenseType(DirLicFile);
    if DirLic <> ltUnknown then
    begin
      AEffectiveLicense := DirLic;
      Exit;
    end;
  end;

  AEffectiveLicense := ARootLicense;
end;

procedure DoCheck;
var
  Files: TStringList;
  Blacklist: TStringList;
  I: Integer;
  R: TFileResult;
  HadProblem: Boolean;
  OutText: string;
  RootLicFile: string;
  RootLicense, EffectiveLicense: TLicenseType;
  HasDirLicense: Boolean;
begin
  Files := TStringList.Create;
  try
    if not GetTrackedPasFiles(Files, OutText) then
      raise Exception.Create('Failed to list git tracked Pascal files: ' + Trim(OutText));

    Blacklist := LoadBlacklist(ResolveBlacklistFile);
    try
      FilterBlacklisted(Files, Blacklist);
    finally
      Blacklist.Free;
    end;

    RootLicFile := FindLicenseFile('.');
    if RootLicFile <> '' then
      RootLicense := DetectLicenseType(RootLicFile)
    else
    begin
      RootLicense := ltUnknown;
      WriteLn('[WARNING] No license file found in project root');
    end;

    HadProblem := False;

    for I := 0 to Files.Count - 1 do
    begin
      R := ScanPasFile(Files[I], GCurrentYear);

      ResolveFileLicense(Files[I], RootLicFile, RootLicense,
                         EffectiveLicense, HasDirLicense);

      Write('[INFO] Found ', Files[I]);
      if EffectiveLicense <> ltUnknown then
        Write(' [', LicenseShortName(EffectiveLicense), ']');

      case R.Status of
        fsOk:
          WriteLn(' Is OK ✅');
        fsWarning:
          begin
            WriteLn(' Out of date: ', R.YearValue, ' ⚠️');
            HadProblem := True;
          end;
        fsError:
          begin
            WriteLn(' No Copyright notice found ❌');
            HadProblem := True;
          end;
      end;

      if HasDirLicense and (EffectiveLicense <> ltUnknown) and
         (RootLicense <> ltUnknown) and (EffectiveLicense <> RootLicense) then
        WriteLn('[WARNING] ', Files[I], ': directory license (',
                LicenseShortName(EffectiveLicense), ') differs from root (',
                LicenseShortName(RootLicense), ')');
    end;

    if HadProblem then
      Halt(1);
  finally
    Files.Free;
  end;
end;

function ResolveAuthor(const ARootLicFile: string): string;
begin
  Result := GetEnvironmentVariable('PASBUILD_COPYRIGHT_AUTHOR');
  if (Result = '') and (ARootLicFile <> '') then
  begin
    Result := ExtractAuthorFromLicenseFile(ARootLicFile);
    if Result <> '' then
      WriteLn('[INFO] Using author "', Result, '" from ', ARootLicFile);
  end;
end;

procedure DoFix;
var
  Files: TStringList;
  Blacklist: TStringList;
  Results: array of TFileResult;
  I: Integer;
  HadProblem: Boolean;
  CopyrightTemplate, OutText: string;
  CopyrightTemplateNeeded: Boolean = False;
  Author: UTF8String;
  RootLicFile: string;
  RootLicense, EffectiveLicense: TLicenseType;
  HasDirLicense: Boolean;
begin
  if not IsGitRepo then
  begin
    WriteLn('[ERROR] Will not make changes to files until project is managed by git and has no uncommited changes');
    Halt(1);
  end;

  if HasStagedChanges then
  begin
    WriteLn('[ERROR] Git repository has staged but uncommitted changes');
    Halt(1);
  end;

  if HasUnstagedChanges then
  begin
    WriteLn('[ERROR] Git repository has unstaged changes');
    Halt(1);
  end;

  Files := TStringList.Create;
  try
    if not GetTrackedPasFiles(Files, OutText) then
      raise Exception.Create('Failed to list git tracked Pascal files: ' + Trim(OutText));

    Blacklist := LoadBlacklist(ResolveBlacklistFile);
    try
      FilterBlacklisted(Files, Blacklist);
    finally
      Blacklist.Free;
    end;

    RootLicFile := FindLicenseFile('.');
    if RootLicFile <> '' then
      RootLicense := DetectLicenseType(RootLicFile)
    else
    begin
      RootLicense := ltUnknown;
      WriteLn('[WARNING] No license file found in project root');
    end;

    SetLength(Results, Files.Count);
    HadProblem := False;

    for I := 0 to Files.Count - 1 do
    begin
      Results[I] := ScanPasFile(Files[I], GCurrentYear);

      ResolveFileLicense(Files[I], RootLicFile, RootLicense,
                         EffectiveLicense, HasDirLicense);

      Write('[INFO] Found ', Files[I]);
      if EffectiveLicense <> ltUnknown then
        Write(' [', LicenseShortName(EffectiveLicense), ']');
      WriteLn;

      case Results[I].Status of
        fsOk:
          WriteLn('[INFO] Copyright exists and is current ✅');
        fsWarning:
          begin
            WriteLn('[WARNING] Copyright exists but is not up to date ⚠️');
            HadProblem := True;
          end;
        fsError:
          begin
            WriteLn('[ERROR] No Copyright found ❌');
            HadProblem := True;
          end;
      end;

      if HasDirLicense and (EffectiveLicense <> ltUnknown) and
         (RootLicense <> ltUnknown) and (EffectiveLicense <> RootLicense) then
        WriteLn('[WARNING] ', Files[I], ': directory license (',
                LicenseShortName(EffectiveLicense), ') differs from root (',
                LicenseShortName(RootLicense), ')');
    end;

    if HadProblem then
    begin
      CopyrightTemplate := GetEnvironmentVariable('PASBUILD_COPYRIGHT_FILE');
      if CopyrightTemplate = '' then
        CopyrightTemplate := 'resources' + PathDelim + 'copyright_stub.txt';

      if not FileExists(CopyrightTemplate) then
        CopyrightTemplate := ''
      else
      begin
        WriteLn('[INFO] Using template in ' + CopyrightTemplate + ' (if needed)');
        CopyrightTemplate := LoadCopyrightTemplate(CopyrightTemplate);
        if (CopyrightTemplate = '') or (Trim(CopyrightTemplate) = '') or
           (Pos('copyright', LowerCase(CopyrightTemplate)) = 0) then
        begin
          WriteLn('[WARNING] Failed to read stub file or it''s empty or it doesn''t seem to have a copyright notice');
          CopyrightTemplate := '';
        end;
      end;

      for I := 0 to High(Results) do
        if Results[I].MissingCopyright then
          CopyrightTemplateNeeded := True;

      WriteLn('[INFO] $who and $year (lowercase) can be used in the copyright stub file. If they exist they will be replaced.');
      WriteLn('[INFO] Set Env variable PASBUILD_COPYRIGHT_AUTHOR to set $who. Year is replaced with the current year.');

      if not CopyrightTemplateNeeded and (CopyrightTemplate = '') then
        WriteLn('[WARNING] Env variable PASBUILD_COPYRIGHT_FILE isn''t set and/or resources' + PathDelim + 'copyright_stub.txt doesn''t exist')
      else if CopyrightTemplate = '' then
      begin
        WriteLn('[ERROR] Env variable PASBUILD_COPYRIGHT_FILE isn''t set and/or resources' + PathDelim + 'copyright_stub.txt doesn''t exist');
        WriteLn('[ERROR] Need Copyright file!');
        Halt(1);
      end;
    end;

    Author := ResolveAuthor(RootLicFile);

    if CopyrightTemplateNeeded and (Pos('$who', CopyrightTemplate) <> 0) and (Author = '') then
    begin
      WriteLn('[ERROR] Copyright file has $who but no author found.',
              ' Set PASBUILD_COPYRIGHT_AUTHOR or add a copyright line to the root license file.');
      Halt(1);
    end
    else
      CopyrightTemplate := StringReplace(CopyrightTemplate, '$who', Author, [rfReplaceAll]);

    for I := 0 to High(Results) do
    begin
      if Results[I].FoundCopyright and Results[I].NeedsYearUpdate then
        ApplyFix(Results[I].FileName, Results[I], CopyrightTemplate, GCurrentYear)
      else if Results[I].MissingCopyright then
      begin
        if CopyrightTemplate = '' then
        begin
          WriteLn('[ERROR] PASBUILD_COPYRIGHT_FILE must be set to the literal contents of the copyright message to place at the top of the Pascal file, including comment marks');
          Halt(1);
        end;
        ApplyFix(Results[I].FileName, Results[I], CopyrightTemplate, GCurrentYear);
      end;
    end;
  finally
    Files.Free;
  end;
end;

procedure DoChangeLicense(const AStubFile: string);
var
  Files: TStringList;
  Blacklist: TStringList;
  Results: array of TFileResult;
  I: Integer;
  CopyrightTemplate, OutText: string;
  Author: string;
  RootLicFile: string;
begin
  if not FileExists('project.xml') then
  begin
    WriteLn('[ERROR] --change-license must be run from the project root (project.xml not found)');
    Halt(1);
  end;

  if not IsGitRepo then
  begin
    WriteLn('[ERROR] Not a git repository');
    Halt(1);
  end;

  if HasStagedChanges then
  begin
    WriteLn('[ERROR] Git repository has staged but uncommitted changes');
    Halt(1);
  end;

  if HasUnstagedChanges then
  begin
    WriteLn('[ERROR] Git repository has unstaged changes');
    Halt(1);
  end;

  if not FileExists(AStubFile) then
  begin
    WriteLn('[ERROR] Stub file not found: ', AStubFile);
    Halt(1);
  end;

  CopyrightTemplate := LoadCopyrightTemplate(AStubFile);
  if (Trim(CopyrightTemplate) = '') or (Pos('copyright', LowerCase(CopyrightTemplate)) = 0) then
  begin
    WriteLn('[ERROR] Stub file is empty or contains no copyright notice: ', AStubFile);
    Halt(1);
  end;

  RootLicFile := FindLicenseFile('.');
  Author := ResolveAuthor(RootLicFile);

  if Pos('$who', CopyrightTemplate) <> 0 then
  begin
    if Author = '' then
    begin
      WriteLn('[ERROR] Template contains $who but no author found.',
              ' Set PASBUILD_COPYRIGHT_AUTHOR or add a copyright line to the root license file.');
      Halt(1);
    end;
    CopyrightTemplate := StringReplace(CopyrightTemplate, '$who', Author, [rfReplaceAll]);
  end;

  Files := TStringList.Create;
  try
    if not GetTrackedPasFiles(Files, OutText) then
      raise Exception.Create('Failed to list git tracked Pascal files: ' + Trim(OutText));

    Blacklist := LoadBlacklist(ResolveBlacklistFile);
    try
      FilterBlacklisted(Files, Blacklist);
    finally
      Blacklist.Free;
    end;

    SetLength(Results, Files.Count);
    for I := 0 to Files.Count - 1 do
      Results[I] := ScanPasFile(Files[I], GCurrentYear);

    for I := 0 to High(Results) do
      ApplyChangeLicense(Results[I].FileName, Results[I], CopyrightTemplate, GCurrentYear);
  finally
    Files.Free;
  end;
end;

procedure HandleSpecialArgs;
begin
  if ParamCount >= 1 then
  begin
    if ParamStr(1) = '--pasbuild-phase' then
    begin
      WriteLn('none');
      Halt(0);
    end;

    if ParamStr(1) = '--install-plugin' then
    begin
      InstallPlugin;
      Halt(0);
    end;

    if ParamStr(1) = '--change-license' then
    begin
      if ParamCount < 2 then
      begin
        WriteLn('[ERROR] --change-license requires a stub file argument');
        WriteLn('[INFO]  Usage: pasbuild-copyright --change-license <stub-file>');
        Halt(1);
      end;
      DoChangeLicense(ParamStr(2));
      Halt(0);
    end;
  end;
end;

begin
  GCurrentYear := StrToIntDef(FormatDateTime('yyyy', Date), 0);

  HandleSpecialArgs;
  try
    case DetectMode of
      pmCheck: DoCheck;
      pmFix:   DoFix;
    else
      begin
        WriteLn('[ERROR] Unknown runtime mode. Rename executable to pasbuild-copyright-check or pasbuild-copyright-fix');
        WriteLn('[INFO] run with --install-plugin to create those and install them');
        Halt(1);
      end;
    end;
  except
    on E: Exception do
    begin
      WriteLn('[ERROR] ' + E.Message + '❌');
      Halt(1);
    end;
  end;
end.
