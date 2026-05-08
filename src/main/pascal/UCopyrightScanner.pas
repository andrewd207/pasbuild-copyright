{
  pasbuild-copyright - A plugin for pasbuild to help administer copyright
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD 3-Clause License. See LICENSE file for details.
}
unit UCopyrightScanner;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math;

const
  CScanLineLimit = 20;

type
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

function ScanPasFile(const AFileName: string; ACurrentYear: Integer): TFileResult;
procedure ApplyFix(const AFileName: string; const Scan: TFileResult; CopyrightTemplate: string; ACurrentYear: Integer);
procedure ApplyChangeLicense(const AFileName: string; const Scan: TFileResult; const NewTemplate: string; ACurrentYear: Integer);
function LoadCopyrightTemplate(const AFileName: string): string;

implementation

function ExtractYear(const S: string; out AYear: Integer): Boolean;
var
  I: Integer;
  T: string;
begin
  Result := False;
  AYear := 0;
  for I := Length(S) - 3 downto 1 do
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
  I: Integer;
begin
  // Strip leading whitespace and comment delimiters ({ (* // * space tab)
  // so that "copyright" must be the first meaningful word on the line.
  // This avoids false matches on description lines like
  //   "pasbuild-copyright - A plugin to administer copyright"
  // where "copyright" appears mid-line or embedded in a compound name.
  L := LowerCase(TrimLeft(S));
  I := 1;
  while (I <= Length(L)) and (L[I] in ['{', '(', '*', '/', ' ', #9]) do
    Inc(I);
  L := Copy(L, I, MaxInt);

  Result := (Copy(L, 1, 9) = 'copyright') or
            (Pos('(c)', L) > 0) or
            (Pos('©', L) > 0);
end;

function IsBlockCommentStart(const S: string): Boolean;
begin
  Result := (Pos('{', S) > 0) or (Pos('(*', S) > 0);
end;

function ReplaceLastYear(const S: string; NewYear: Integer): string;
var
  I: Integer;
  T: string;
begin
  Result := S;
  for I := Length(S) - 3 downto 1 do
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

procedure InsertHeaderTemplate(Lines: TStrings; TemplateText: string; ACurrentYear: Integer);
var
  T: TStringList;
  I: Integer;
begin
  TemplateText := StringReplace(TemplateText, '$year', IntToStr(ACurrentYear), []);

  T := TStringList.Create;
  try
    T.Text := NormalizeTemplate(TemplateText);
    while (T.Count > 0) and (Trim(T[T.Count - 1]) = '') do
      T.Delete(T.Count - 1);

    for I := T.Count - 1 downto 0 do
      Lines.Insert(0, T[I]);

    if T.Count > 0 then
      Lines.Insert(T.Count, '');
  finally
    T.Free;
  end;
end;

function ScanPasFile(const AFileName: string; ACurrentYear: Integer): TFileResult;
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
          Result.NeedsYearUpdate := (Y <> ACurrentYear);
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

procedure ApplyFix(const AFileName: string; const Scan: TFileResult; CopyrightTemplate: string; ACurrentYear: Integer);
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
            ReplaceLastYear(Lines[Scan.ExistingCopyrightLineIndex], ACurrentYear);
        Lines.SaveToFile(AFileName);
        WriteLn('[INFO] Updated copyright year ', AFileName);
      end;
    end
    else
    begin
      InsertHeaderTemplate(Lines, CopyrightTemplate, ACurrentYear);
      Lines.SaveToFile(AFileName);
      WriteLn('[INFO] Added copyright header ', AFileName);
    end;
  finally
    Lines.Free;
  end;
end;

{ Scans backward from ACopyrightLine to find the line that opens the
  enclosing block comment ({ or (*). Returns ACopyrightLine if none found. }
function FindBlockStart(Lines: TStrings; ACopyrightLine: Integer): Integer;
begin
  Result := ACopyrightLine;
  while (Result > 0) and
        (Pos('{', Lines[Result]) = 0) and
        (Pos('(*', Lines[Result]) = 0) do
    Dec(Result);
end;

{ Returns the line index of the closing delimiter (} or *)) for the block
  comment that opens on AStartLine. Handles single-line blocks. }
function FindBlockEnd(Lines: TStrings; AStartLine: Integer): Integer;
var
  IsParenStar: Boolean;
  OpenPos, ClosePos: Integer;
begin
  IsParenStar := Pos('(*', Lines[AStartLine]) > 0;

  if IsParenStar then
  begin
    OpenPos  := Pos('(*', Lines[AStartLine]);
    ClosePos := Pos('*)', Lines[AStartLine]);
  end
  else
  begin
    OpenPos  := Pos('{', Lines[AStartLine]);
    ClosePos := Pos('}', Lines[AStartLine]);
  end;

  // Closing delimiter on the same line as the opening one
  if (ClosePos > 0) and (ClosePos > OpenPos) then
  begin
    Result := AStartLine;
    Exit;
  end;

  // Multi-line: scan forward
  Result := AStartLine + 1;
  while Result < Lines.Count do
  begin
    if IsParenStar then
    begin
      if Pos('*)', Lines[Result]) > 0 then Exit;
    end
    else
    begin
      if Pos('}', Lines[Result]) > 0 then Exit;
    end;
    Inc(Result);
  end;
  Result := Lines.Count - 1; // fallback: last line
end;

procedure ApplyChangeLicense(const AFileName: string; const Scan: TFileResult;
                              const NewTemplate: string; ACurrentYear: Integer);
var
  Lines: TStringList;
  BlockStart, BlockEnd, I: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);

    if Scan.FoundCopyright then
    begin
      if Scan.OriginalHeaderStyle = 'block' then
      begin
        BlockStart := FindBlockStart(Lines, Scan.ExistingCopyrightLineIndex);
        BlockEnd   := FindBlockEnd(Lines, BlockStart);
        // Remove a trailing blank line too so the new header doesn't double-space
        if (BlockEnd + 1 < Lines.Count) and (Trim(Lines[BlockEnd + 1]) = '') then
          Inc(BlockEnd);
        for I := BlockEnd downto BlockStart do
          Lines.Delete(I);
      end
      else
        Lines.Delete(Scan.ExistingCopyrightLineIndex);
    end;

    InsertHeaderTemplate(Lines, NewTemplate, ACurrentYear);
    Lines.SaveToFile(AFileName);
    WriteLn('[INFO] Changed license header in ', AFileName);
  finally
    Lines.Free;
  end;
end;

function LoadCopyrightTemplate(const AFileName: string): string;
var
  Stream: TStringStream;
begin
  Result := '';
  Stream := TStringStream.Create('');
  try
    try
      Stream.LoadFromFile(AFileName);
      Result := Stream.DataString;
    except
    end;
  finally
    Stream.Free;
  end;
end;

end.
