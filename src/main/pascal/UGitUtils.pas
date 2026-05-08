{
  pasbuild-copyright - A plugin for pasbuild to help administer copyright
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD 3-Clause License. See LICENSE file for details.
}
unit UGitUtils;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process;

function RunGit(const Args: array of string; out OutputText: string; out ExitCode: Integer): Boolean;
function IsGitRepo: Boolean;
function HasStagedChanges: Boolean;
function HasUnstagedChanges: Boolean;
function GetTrackedPasFiles(AList: TStrings; var OutText: string): Boolean;

implementation

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

function GetTrackedPasFiles(AList: TStrings; var OutText: string): Boolean;
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
      if S <> '' then
        AList.Add(S);
    end;
  finally
    Lines.Free;
  end;
end;

end.
