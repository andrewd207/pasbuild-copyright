{
  pasbuild-copyright - A plugin for pasbuild to help administer copyright
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD 3-Clause License. See LICENSE file for details.
}
unit ULicenseDetect;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TLicenseType = (ltUnknown, ltMIT, ltISC, ltBSD2, ltBSD3,
                  ltApache2, ltMPL2,
                  ltLGPL2, ltLGPL3,
                  ltGPL2, ltGPL3, ltAGPL3,
                  ltProprietaryLike);

const
  CLicenseFileNames: array[0..10] of string = (
    'LICENSE', 'LICENSE.txt', 'LICENSE.md', 'LICENSE.rst',
    'LICENCE', 'LICENCE.txt', 'LICENCE.md',
    'COPYING', 'COPYING.txt', 'COPYING.lesser',
    'COPYRIGHT'
  );

{ Returns the path to the license file in ADir, or '' if none found. }
function FindLicenseFile(const ADir: string): string;

{ Reads AFileName and returns the detected license type.
  Returns ltUnknown when the content does not match any known pattern. }
function DetectLicenseType(const AFileName: string): TLicenseType;

{ Short display name for use in log output, e.g. 'BSD-3', 'MIT', '?'. }
function LicenseShortName(ALicense: TLicenseType): string;

{ Reads the license file and extracts the author name from its copyright line.
  Looks for the rightmost year >= 1900 and returns everything after it.
  Returns '' if no such line is found. }
function ExtractAuthorFromLicenseFile(const AFileName: string): string;

implementation

function FindLicenseFile(const ADir: string): string;
var
  I: Integer;
  Path: string;
begin
  Result := '';
  for I := Low(CLicenseFileNames) to High(CLicenseFileNames) do
  begin
    Path := IncludeTrailingPathDelimiter(ADir) + CLicenseFileNames[I];
    if FileExists(Path) then
    begin
      Result := Path;
      Exit;
    end;
  end;
end;

function DetectLicenseType(const AFileName: string): TLicenseType;
var
  Lower: string;
  Stream: TStringStream;
begin
  Result := ltUnknown;
  Stream := TStringStream.Create('');
  try
    try
      Stream.LoadFromFile(AFileName);
      Lower := LowerCase(Stream.DataString);
    except
      Exit;
    end;
  finally
    Stream.Free;
  end;

  // AGPL must come before GPL — AGPL text also contains "general public license"
  if Pos('gnu affero general public license', Lower) > 0 then
    Exit(ltAGPL3);

  // LGPL must come before GPL for the same reason
  if (Pos('gnu lesser general public license', Lower) > 0) or
     (Pos('gnu library general public license', Lower) > 0) then
  begin
    if Pos('version 3', Lower) > 0 then
      Exit(ltLGPL3);
    Exit(ltLGPL2); // covers 2.0 and 2.1
  end;

  if Pos('gnu general public license', Lower) > 0 then
  begin
    if Pos('version 3', Lower) > 0 then
      Exit(ltGPL3);
    if Pos('version 2', Lower) > 0 then
      Exit(ltGPL2);
  end;

  if (Pos('apache license', Lower) > 0) and
     ((Pos('version 2.0', Lower) > 0) or (Pos('version 2,', Lower) > 0)) then
    Exit(ltApache2);

  if (Pos('mozilla public license', Lower) > 0) and (Pos('2.0', Lower) > 0) then
    Exit(ltMPL2);

  // MIT — check before BSD; the grant phrase is also present in some BSD variants
  // but "mit license" as a title is unambiguous
  if (Pos('mit license', Lower) > 0) or
     (Pos('permission is hereby granted, free of charge', Lower) > 0) then
    Exit(ltMIT);

  // BSD — distinguish 2-clause from 3-clause by the "neither the name" endorsement clause
  if Pos('redistribution and use in source and binary forms', Lower) > 0 then
  begin
    if Pos('neither the name', Lower) > 0 then
      Exit(ltBSD3)
    else
      Exit(ltBSD2);
  end;

  if (Pos('isc license', Lower) > 0) or
     ((Pos(' isc ', Lower) > 0) and (Pos('permission to use, copy, modify', Lower) > 0)) then
    Exit(ltISC);

  if (Pos('all rights reserved', Lower) > 0) and
     (Pos('redistribution', Lower) = 0) and
     (Pos('permission is hereby granted', Lower) = 0) then
    Exit(ltProprietaryLike);
end;

function LicenseShortName(ALicense: TLicenseType): string;
begin
  case ALicense of
    ltMIT:             Result := 'MIT';
    ltISC:             Result := 'ISC';
    ltBSD2:            Result := 'BSD-2';
    ltBSD3:            Result := 'BSD-3';
    ltApache2:         Result := 'Apache-2';
    ltMPL2:            Result := 'MPL-2';
    ltLGPL2:           Result := 'LGPL-2';
    ltLGPL3:           Result := 'LGPL-3';
    ltGPL2:            Result := 'GPL-2';
    ltGPL3:            Result := 'GPL-3';
    ltAGPL3:           Result := 'AGPL-3';
    ltProprietaryLike: Result := 'Proprietary';
  else
    Result := '?';
  end;
end;

function ExtractAuthorFromLicenseFile(const AFileName: string): string;
var
  Stream: TStringStream;
  Lines: TStringList;
  LineIdx, CharIdx, AuthorStart, Year: Integer;
  S, T: string;
begin
  Result := '';
  Stream := TStringStream.Create('');
  try
    try
      Stream.LoadFromFile(AFileName);
    except
      Exit;
    end;
    Lines := TStringList.Create;
    try
      Lines.Text := Stream.DataString;
      for LineIdx := 0 to Lines.Count - 1 do
      begin
        S := Lines[LineIdx];
        if Pos('copyright', LowerCase(S)) = 0 then
          Continue;
        // Scan right-to-left for the rightmost year >= 1900, matching the
        // same direction used when extracting/replacing years in source files
        for CharIdx := Length(S) - 3 downto 1 do
        begin
          T := Copy(S, CharIdx, 4);
          if (T[1] in ['0'..'9']) and (T[2] in ['0'..'9']) and
             (T[3] in ['0'..'9']) and (T[4] in ['0'..'9']) then
          begin
            Year := StrToIntDef(T, 0);
            if Year >= 1900 then
            begin
              AuthorStart := CharIdx + 4;
              // Skip comma and whitespace that typically follow the year
              while (AuthorStart <= Length(S)) and
                    (S[AuthorStart] in [',', ' ', #9]) do
                Inc(AuthorStart);
              Result := Trim(Copy(S, AuthorStart, MaxInt));
              Exit;
            end;
          end;
        end;
      end;
    finally
      Lines.Free;
    end;
  finally
    Stream.Free;
  end;
end;

end.
