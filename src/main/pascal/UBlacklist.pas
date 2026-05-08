{
  pasbuild-copyright - A plugin for pasbuild to help administer copyright
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD 3-Clause License. See LICENSE file for details.
}
unit UBlacklist;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, RegExpr;

function LoadBlacklist(const AFileName: string): TStringList;
function IsBlacklisted(const AFileName: string; ABlacklist: TStrings): Boolean;
procedure FilterBlacklisted(AFiles: TStrings; ABlacklist: TStrings);
function ResolveBlacklistFile: string;

implementation

function NormalizePathSeps(const APath: string): string;
begin
  Result := StringReplace(APath, '\', '/', [rfReplaceAll]);
end;

function LoadBlacklist(const AFileName: string): TStringList;
var
  Lines: TStringList;
  I: Integer;
  S: string;
begin
  Result := TStringList.Create;
  if not FileExists(AFileName) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    for I := 0 to Lines.Count - 1 do
    begin
      S := Trim(Lines[I]);
      if (S = '') or (Copy(S, 1, 2) = '//') or (S[1] = '#') then
        Continue;
      Result.Add(S);
    end;
  finally
    Lines.Free;
  end;
end;

function IsBlacklisted(const AFileName: string; ABlacklist: TStrings): Boolean;
var
  I: Integer;
  Re: TRegExpr;
begin
  Result := False;
  if ABlacklist.Count = 0 then
    Exit;
  Re := TRegExpr.Create;
  try
    for I := 0 to ABlacklist.Count - 1 do
    begin
      Re.Expression := ABlacklist[I];
      try
        if Re.Exec(NormalizePathSeps(AFileName)) then
          Exit(True);
      except
        on E: ERegExpr do
          WriteLn('[WARNING] Invalid blacklist regex: ', ABlacklist[I], ' — ', E.Message);
      end;
    end;
  finally
    Re.Free;
  end;
end;

procedure FilterBlacklisted(AFiles: TStrings; ABlacklist: TStrings);
var
  I: Integer;
begin
  for I := AFiles.Count - 1 downto 0 do
    if IsBlacklisted(AFiles[I], ABlacklist) then
    begin
      WriteLn('[INFO] Skipping blacklisted file: ', AFiles[I]);
      AFiles.Delete(I);
    end;
end;

function ResolveBlacklistFile: string;
begin
  Result := GetEnvironmentVariable('PASBUILD_COPYRIGHT_BLACKLIST');
  if Result = '' then
    Result := 'resources' + PathDelim + 'copyright_blacklist.txt';
end;

end.
