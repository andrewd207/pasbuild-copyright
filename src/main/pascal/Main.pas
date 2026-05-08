program main;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, StrUtils, Process, Math, DateUtils
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

  CScanLineLimit = 20;

type
  TMode = (pmUnknown, pmCheck, pmFix);

  TFileStatus = (fsOk, fsWarning, fsError);

  TFileResult = record
    FileName: string;
    Status: TFileStatus;
    FoundCopyright: Boolean;
    FoundYear: Boolean;
    YearValue: Integer;
    NeedsYearUpdate: Boolean;
    MissingCopyright: Boolean;
    OriginalHeaderStyle: string;
    ExistingCopyrightLineIndex: Integer;
  end;

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
  S := IncludeTrailingPathDelimiter(CDefaultInstalledFolder) + 'plugins'+ PathDelim;
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

function RunGit(const Args: array of string; out OutputText: string; out ExitCode: Integer): Boolean;
var
  Cmds: TStringArray;
  I: Integer;
begin
  SetLength(Cmds, Length(Args));
  for I := 0 to High(Args) do
    Cmds[I] := Args[I];
  Result := RunCommandInDir(GetCurrentDir, 'git', Cmds, OutputText, ExitCode, []) = 0;
end;

function IsGitRepo: Boolean;
var
  OutText: string;
  ExitCode: Integer;
begin
  Result := RunGit(['rev-parse', '--is-inside-work-tree'], OutText, ExitCode)
            and (ExitCode = 0)
            and (Pos('true', LowerCase(Trim(OutText))) > 0);
end;

function HasStagedChanges: Boolean;
var
  OutText: string;
  ExitCode: Integer;
begin
  Result := not RunGit(['diff', '--cached', '--name-only'], OutText, ExitCode)
            or (ExitCode <> 0)
            or (Trim(OutText) <> '');
end;

function HasUnstagedChanges: Boolean;
var
  OutText: string;
  ExitCode: Integer;
begin
  Result := not RunGit(['diff', '--name-only'], OutText, ExitCode)
            or (ExitCode <> 0)
            or (Trim(OutText) <> '');
end;

function GetTrackedPasFiles(AList: TStrings; var OutText: String): Boolean;
var
  ExitCode, I: Integer;
  Lines: TStringList;
  S: string;
begin
  OutText := '';
  AList.Clear;
  Result := RunGit(['ls-files', '*.pas'], OutText, ExitCode) and (ExitCode = 0);
  if not Result then
    Exit;

  Lines := TStringList.Create;
  try
    Lines.Text := StringReplace(OutText, #13, '', [rfReplaceAll]);
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      WriteLn('F: ', S);
      if S <> '' then
        AList.Add(S);
    end;
  finally
    Lines.Free;
  end;
end;

function ExtractYear(const S: string; out AYear: Integer): Boolean;
var
  I: Integer;
  T: string;
begin
  Result := False;
  AYear := 0;
  for I := 1 to Length(S) - 3 do
  begin
    T := Copy(S, I, 4);
    if (T[1] in ['0'..'9']) and (T[2] in ['0'..'9']) and
       (T[3] in ['0'..'9']) and (T[4] in ['0'..'9']) then
    begin
      AYear := StrToIntDef(T, 0);
      if AYear >= 1900 then
      begin
        Result := True;
        Exit;
      end;
    end;
  end;
end;

function LooksLikeCopyrightLine(const S: string): Boolean;
var
  L: string;
begin
  L := LowerCase(S);
  Result := (Pos('copyright', L) > 0) or (Pos('(c)', L) > 0) or (Pos('©', L) > 0);
end;

function IsBlockCommentStart(const S: string): Boolean;
begin
  Result := (Pos('{', S) > 0) or (Pos('(*', S) > 0);
end;

function ScanPasFile(const AFileName: string): TFileResult;
var
  Lines: TStringList;
  I, MaxLine, Y: Integer;
  S: string;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.FileName := AFileName;
  Result.Status := fsError;
  Result.MissingCopyright := True;
  Result.ExistingCopyrightLineIndex := -1;

  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    MaxLine := Min(CScanLineLimit, Lines.Count);

    for I := 0 to MaxLine - 1 do
    begin
      S := Lines[I];
      if LooksLikeCopyrightLine(S) then
      begin
        Result.FoundCopyright := True;
        Result.MissingCopyright := False;
        Result.ExistingCopyrightLineIndex := I;

        if ExtractYear(S, Y) then
        begin
          Result.FoundYear := True;
          Result.YearValue := Y;
          Result.NeedsYearUpdate := (Y <> GCurrentYear);
          if Result.NeedsYearUpdate then
            Result.Status := fsWarning
          else
            Result.Status := fsOk;
        end
        else
        begin
          Result.FoundYear := False;
          Result.NeedsYearUpdate := True;
          Result.Status := fsWarning;
        end;

        if IsBlockCommentStart(S) then
          Result.OriginalHeaderStyle := 'block'
        else
          Result.OriginalHeaderStyle := 'line';
        Exit;
      end;
    end;

    Result.Status := fsError;
    Result.MissingCopyright := True;
  finally
    Lines.Free;
  end;
end;

function ReplaceFirstYear(const S: string; NewYear: Integer): string;
var
  I: Integer;
  T: string;
begin
  Result := S;
  for I := 1 to Length(S) - 3 do
  begin
    T := Copy(S, I, 4);
    if (T[1] in ['0'..'9']) and (T[2] in ['0'..'9']) and
       (T[3] in ['0'..'9']) and (T[4] in ['0'..'9']) then
    begin
      Result := Copy(S, 1, I - 1) + IntToStr(NewYear) + Copy(S, I + 4, MaxInt);
      Exit;
    end;
  end;
end;

function NormalizeTemplate(const S: string): string;
begin
  Result := StringReplace(S, #13#10, LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, #10, LineEnding, [rfReplaceAll]);
  Result := StringReplace(Result, #13, LineEnding, [rfReplaceAll]);
end;

procedure InsertHeaderTemplate(Lines: TStrings; TemplateText: string);
var
  T: TStringList;
  I: Integer;
begin
  TemplateText := StringReplace(TemplateText, '$year', IntToStr(GCurrentYear), []);

  T := TStringList.Create;
  try
    T.Text := NormalizeTemplate(TemplateText);
    while (T.Count > 0) and (Trim(T[T.Count - 1]) = '') do
      T.Delete(T.Count - 1);

    for I := T.Count - 1 downto 0 do
      Lines.Insert(0, T[I]);

    if (T.Count > 0) then
      Lines.Insert(T.Count, '');
  finally
    T.Free;
  end;
end;

procedure ApplyFix(const AFileName: string; const Scan: TFileResult; CopyrightTemplate: string);
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);

    if Scan.FoundCopyright then
    begin
      if Scan.NeedsYearUpdate and (Scan.ExistingCopyrightLineIndex >= 0) then
      begin
        if Scan.FoundYear then
          Lines[Scan.ExistingCopyrightLineIndex] :=
            ReplaceFirstYear(Lines[Scan.ExistingCopyrightLineIndex], GCurrentYear);
        Lines.SaveToFile(AFileName);
        WriteLn('[INFO] Updated copyright year ', AFileName);
      end;
    end
    else
    begin
      InsertHeaderTemplate(Lines, CopyrightTemplate);
      Lines.SaveToFile(AFileName);
      WriteLn('[INFO] Added copyright header ', AFileName);
    end;
  finally
    Lines.Free;
  end;
end;

procedure DoCheck;
var
  Files: TStringList;
  I: Integer;
  R: TFileResult;
  HadProblem: Boolean;
  OutText: String;
begin
  Files := TStringList.Create;
  try
    if not GetTrackedPasFiles(Files, OutText) then
      raise Exception.Create('Failed to list git tracked Pascal files: '+ Trim(OutText));

    HadProblem := False;

    for I := 0 to Files.Count - 1 do
    begin
      R := ScanPasFile(Files[I]);
      WriteLn('[INFO] Found ', Files[I]);

      case R.Status of
        fsOk:
          WriteLn('[INFO] Copyright exists and is current ✅');
        fsWarning:
          begin
            WriteLn('[WARNING] Copyright exists but is not up to date ⚠️');
            HadProblem := True;
          end;
        fsError:
          begin
            WriteLn('[ERROR] ↑ No Copyright notice found in file ↑ ❌');
            HadProblem := True;
          end;
      end;
    end;

    if HadProblem then
      Halt(1);
  finally
    Files.Free;
  end;
end;

function LoadCopyrightTemplate(AFileName: String): String;
var
  Stream: TStringStream;
begin
  try
    Stream := TStringStream.Create;
    Stream.LoadFromFile(AFileName);
    Result := Stream.DataString;
  except
    Result := '';
  end;
  Stream.Free;
end;

procedure DoFix;
var
  Files: TStringList;
  Results: array of TFileResult;
  I: Integer;
  HadProblem: Boolean;
  CopyrightTemplate, OutText: string;
  CopyrightTemplateNeeded: Boolean = False;
  Author: UTF8String;
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
      raise Exception.Create('Failed to list git tracked Pascal files: '+ Trim(OutText));

    SetLength(Results, Files.Count);
    HadProblem := False;

    for I := 0 to Files.Count - 1 do
    begin
      Results[I] := ScanPasFile(Files[I]);
      WriteLn('[INFO] Found ', Files[I]);

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
    end;

    if HadProblem then
    begin
      CopyrightTemplate := GetEnvironmentVariable('PASBUILD_COPYRIGHT_FILE');
      if CopyrightTemplate = '' then
        CopyrightTemplate:= 'resources' + PathDelim + 'copyright_stub.txt';

      if not FileExists(CopyrightTemplate) then
        CopyrightTemplate:=''
      else
      begin
        WriteLn('[INFO] Using template in ' + CopyrightTemplate + ' (if needed)');
        CopyrightTemplate:=LoadCopyrightTemplate(CopyrightTemplate);
        if (CopyrightTemplate = '') or (Trim(CopyrightTemplate) = '') or (Pos('copyright', LowerCase(CopyrightTemplate)) = 0)then
        begin
          WriteLn('[WARNING] Failed to read stub file or it''s empty or it doesn''t seem to have a copyright notice');
          CopyrightTemplate := '';
        end;
      end;


      for I := 0 to High(Results) do
        if Results[I].MissingCopyright {or Results[I].NeedsYearUpdate} then
          CopyrightTemplateNeeded:=True;

      WriteLn('[INFO] $who and $year (lowercase) can be used in the copyright stub file. If they exist they will be replaced.');
      Writeln('[INFO] Set Env variable PASBUILD_COPYRIGHT_AUTHOR to set $who. Year is replaced with the current year.');

      if not CopyrightTemplateNeeded and (CopyrightTemplate = '') then
        WriteLn('[WARNING] Env variable PASBUILD_COPYRIGHT_FILE isn''t set and/or resources' + PathDelim + 'copyright_stub.txt doesn''t exist')
      else if CopyrightTemplate = '' then begin
        WriteLn('[ERROR] Env variable PASBUILD_COPYRIGHT_FILE isn''t set and/or resources' + PathDelim + 'copyright_stub.txt doesn''t exist');
        WriteLn('[ERROR] Need Copyright file!');
        Halt(1);
      end;
    end;

    Author := GetEnvironmentVariable(UTF8String('PASBUILD_COPYRIGHT_AUTHOR'));

    if CopyrightTemplateNeeded and (Pos('$who', CopyrightTemplate) <> 0) and (Author = '') then
    begin
      WriteLn('[ERROR] Copyright file has $who but PASBUILD_COPYRIGHT_AUTHOR env variable not set!');
      Halt(1);
    end
    else
      CopyrightTemplate:=StringReplace(CopyrightTemplate, '$who', Author, [rfReplaceAll]);

    for I := 0 to High(Results) do
    begin
      if Results[I].FoundCopyright and Results[I].NeedsYearUpdate then
        ApplyFix(Results[I].FileName, Results[I], CopyrightTemplate)
      else if Results[I].MissingCopyright then
      begin
        if CopyrightTemplate = '' then
        begin
          WriteLn('[ERROR] PASBUILD_COPYRIGHT_FILE must be set to the literal contents of the copyright message to place at the top of the Pascal file, including comment marks');
          Halt(1);
        end;
        ApplyFix(Results[I].FileName, Results[I], CopyrightTemplate);
      end;
    end;
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
  end;
end;

begin
  GCurrentYear := StrToIntDef(FormatDateTime('yyyy', Date), 0);

  HandleSpecialArgs;
  try
    case DetectMode of
      pmCheck: DoCheck;
      pmFix: DoFix;
    else
      begin
        WriteLn('[ERROR] Unknown runtime mode. Rename executable to pasbuild-copyright-check or pasbuild-copyright-fix');
        WriteLn('[INFO] run with --install-plugin to create those and install them');
        Halt(1);
      end;
    end;
  except
    on e: Exception do
    begin
      WriteLn('[ERROR] '+ E.Message+'❌');
      Halt(1);
    end;

  end;
end.
