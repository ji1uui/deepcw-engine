{ 版と許諾条項の窓（付録 CP、要件 NFR-8.1・NFR-8.2・NFR-8.4）。

  **モードレスです。**受信しながら開いておけます。左に文書の一覧、右にその
  全文を出します:

    - DeepCW 自身の許諾（AGPL-3.0。`LICENSE`）
    - 同梱した部品の表記（`THIRD-PARTY-NOTICES.md`）
    - 同梱した各部品の条項（`licences/` の中身。配布物だけにある）
    - 総務省の無線局等情報検索の取得元の明示（規約第 3 条）

  **無いものを「在る」と出しません。**開発の木から動かしているときは
  `licences/` が無く、その旨を本文の欄に書きます（要件 NFR-8.4 と同じ考え）。
  中身は**開いたときに読みます**——窓を作るたびに数百 KB の条項を読み込まない
  ためです。

  The version and licence window (appendix CP; requirements NFR-8.1, NFR-8.2,
  NFR-8.4). **Modeless**: it can stay open while receiving. On the left the
  documents, on the right the chosen one in full: DeepCW's own licence
  (AGPL-3.0, `LICENSE`), the notices for bundled parts
  (`THIRD-PARTY-NOTICES.md`), each bundled part's terms (`licences/`, present
  only in a distribution), and the ministry search's source statement
  (article 3 of its terms). **Nothing missing is shown as present**: run from a
  build tree there is no `licences/`, and the text area says so. A document is
  **read when chosen**, not every time the window is made. }
unit AboutWindow;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Graphics;

type
  TAboutWindow = class(TForm)
  private
    FTitle: TLabel;
    FSummary: TLabel;
    FList: TListBox;
    FText: TMemo;
    FOpenFolder: TButton;
    FClose: TButton;
    FAttribution: string;
    { 一覧の各行が指すファイル。空なら `FAttribution` を出す。
      The file each row refers to; empty means `FAttribution`. }
    FPaths: TStringList;
    procedure ListChanged(Sender: TObject; User: Boolean);
    procedure OpenFolderClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure ShowDocument(Index: Integer);
  public
    constructor CreateWith(AOwner: TComponent; const Attribution: string);
    destructor Destroy; override;
    { 一覧と見出しを作り直します（言語を変えたとき・開き直したとき）。
      Rebuilds the list and headings (on a language change, on reopening). }
    procedure Refresh;
  end;

{ `LICENSE` と `THIRD-PARTY-NOTICES.md` の場所。無ければ空。配布物では実行
  ファイルの隣（`.app` では入れ物の外）、開発の木ではリポジトリの根と
  `lazarus/dist-notes/` にあります。
  Where `LICENSE` and `THIRD-PARTY-NOTICES.md` are, or empty: beside the
  executable in a distribution (outside the `.app` on macOS); at the
  repository root and in `lazarus/dist-notes/` in a build tree. }
function FindReadable(const FileName: string): string;

implementation

uses
  LCLIntf, DeepCW.Types, DeepCW.Platform, DeepCW.LicenseLookup, UiText;

resourcestring
  RsAboutTitle = 'このアプリについて';
  RsAboutProduct = 'DeepCW Morse Station  版 %s';
  RsAboutSummary = 'このアプリケーションは AGPL-3.0 で無償配布しています。' +
    '同梱した部品の条項と、総務省の検索の取得元をここで読めます。';
  RsAboutOwnLicence = 'DeepCW の許諾（AGPL-3.0）';
  RsAboutNotices = '同梱した部品の一覧';
  RsAboutAttribution = '総務省の無線局等情報検索';
  RsAboutNotFound = '見つかりません: %s' + #10 + #10 +
    '開発のために組んだまま動かしているときは、配布物に入る条項の一部が' +
    'ありません。配布物（zip）を展開したものでは見つかります。';
  RsAboutNoLicences = '同梱の部品の条項: 見つかりません';
  RsAboutNoLicencesNote = '同梱した部品（ONNX Runtime・PortAudio）の条項は、' +
    '配布物の licences フォルダに入ります。開発のために組んだまま動かして' +
    'いるときはありません。';
  RsAboutOpenFolder = '条項のフォルダを開く';
  RsAboutClose = '閉じる';

function FindReadable(const FileName: string): string;
var
  Base: string;
  Candidates: array[0..4] of string;
  I: Integer;
begin
  Base := IncludeTrailingPathDelimiter(ExtractFilePath(ExecutablePath));
  { 配布物（実行ファイルの隣）、`.app`（`Contents/Resources/` から 3 つ上が
    入れ物の外）、開発の木（`lazarus/app/` から根と `dist-notes/`）。
    The distribution (beside the executable), the `.app` (three levels above
    `Contents/Resources/` is outside the bundle), the build tree (the root
    and `dist-notes/` from `lazarus/app/`). }
  Candidates[0] := Base + FileName;
  Candidates[1] := ResourceDirectory + '..' + PathDelim + '..' + PathDelim +
    '..' + PathDelim + FileName;
  Candidates[2] := Base + '..' + PathDelim + '..' + PathDelim + FileName;
  Candidates[3] := Base + '..' + PathDelim + 'dist-notes' + PathDelim + FileName;
  Candidates[4] := Base + '..' + PathDelim + FileName;
  for I := Low(Candidates) to High(Candidates) do
    if FileExists(Candidates[I]) then
      Exit(ExpandFileName(Candidates[I]));
  Result := '';
end;

constructor TAboutWindow.CreateWith(AOwner: TComponent; const Attribution: string);
var
  Top_, Buttons: TPanel;
begin
  inherited CreateNew(AOwner);
  FAttribution := Attribution;
  FPaths := TStringList.Create;
  BorderStyle := bsSizeable;
  Position := poMainFormCenter;
  Width := 820;
  Height := 560;
  Constraints.MinWidth := 560;
  Constraints.MinHeight := 360;
  RegisterCaption(Self, @RsAboutTitle);

  Top_ := TPanel.Create(Self);
  Top_.Parent := Self;
  Top_.Align := alTop;
  Top_.Height := 64;
  Top_.BevelOuter := bvNone;
  FTitle := TLabel.Create(Top_);
  FTitle.Parent := Top_;
  FTitle.SetBounds(14, 10, 400, 20);
  FTitle.Font.Style := [fsBold];
  FSummary := TLabel.Create(Top_);
  FSummary.Parent := Top_;
  FSummary.SetBounds(14, 36, 780, 20);
  RegisterCaption(FSummary, @RsAboutSummary);

  { 下の釦の行。左から「条項のフォルダを開く」、右端に「閉じる」。
    The button row: "open the licence folder" on the left, "close" at the
    right edge. }
  Buttons := TPanel.Create(Self);
  Buttons.Parent := Self;
  Buttons.Align := alBottom;
  Buttons.Height := 44;
  Buttons.BevelOuter := bvNone;
  FOpenFolder := TButton.Create(Buttons);
  FOpenFolder.Parent := Buttons;
  FOpenFolder.SetBounds(14, 7, 200, 30);
  FOpenFolder.OnClick := @OpenFolderClick;
  RegisterCaption(FOpenFolder, @RsAboutOpenFolder);
  FClose := TButton.Create(Buttons);
  FClose.Parent := Buttons;
  FClose.Width := 110;
  FClose.Align := alRight;
  FClose.BorderSpacing.Around := 7;
  FClose.OnClick := @CloseClick;
  FClose.Cancel := True;
  RegisterCaption(FClose, @RsAboutClose);

  FList := TListBox.Create(Self);
  FList.Parent := Self;
  FList.Align := alLeft;
  FList.Width := 250;
  FList.BorderSpacing.Left := 14;
  FList.BorderSpacing.Bottom := 4;
  FList.OnSelectionChange := @ListChanged;

  FText := TMemo.Create(Self);
  FText.Parent := Self;
  FText.Align := alClient;
  FText.BorderSpacing.Left := 8;
  FText.BorderSpacing.Right := 14;
  FText.BorderSpacing.Bottom := 4;
  FText.ReadOnly := True;
  FText.ScrollBars := ssAutoVertical;
  FText.WordWrap := True;

  Refresh;
end;

destructor TAboutWindow.Destroy;
begin
  FPaths.Free;
  inherited Destroy;
end;

procedure TAboutWindow.Refresh;
var
  Licences: TStringList;
  Folder: string;
  Search: TSearchRec;
  Was, I: Integer;
begin
  Was := FList.ItemIndex;
  FTitle.Caption := Format(RsAboutProduct, [DEEPCW_VERSION]);
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    FPaths.Clear;
    FList.Items.Add(RsAboutOwnLicence);
    FPaths.Add(FindReadable('LICENSE'));
    FList.Items.Add(RsAboutNotices);
    FPaths.Add(FindReadable('THIRD-PARTY-NOTICES.md'));
    { 同梱した各部品の条項。名前はファイル名のまま出します（部品の名前が入って
      います）。/ Each bundled part's terms, listed by file name (which
      carries the part's name). }
    Folder := LicenceDirectory;
    if Folder <> '' then
    begin
      Licences := TStringList.Create;
      try
        Folder := IncludeTrailingPathDelimiter(Folder);
        if FindFirst(Folder + '*', faAnyFile, Search) = 0 then
          try
            repeat
              if (Search.Attr and faDirectory) = 0 then
                Licences.Add(Search.Name);
            until FindNext(Search) <> 0;
          finally
            SysUtils.FindClose(Search);
          end;
        Licences.Sort;
        for I := 0 to Licences.Count - 1 do
        begin
          FList.Items.Add(ChangeFileExt(Licences[I], ''));
          FPaths.Add(Folder + Licences[I]);
        end;
      finally
        Licences.Free;
      end;
    end
    else
    begin
      FList.Items.Add(RsAboutNoLicences);
      FPaths.Add('?');
    end;
    FList.Items.Add(RsAboutAttribution);
    FPaths.Add('');
  finally
    FList.Items.EndUpdate;
  end;
  FOpenFolder.Enabled := Folder <> '';
  if (Was < 0) or (Was >= FList.Count) then
    Was := 0;
  FList.ItemIndex := Was;
  ShowDocument(Was);
end;

procedure TAboutWindow.ShowDocument(Index: Integer);
var
  Path: string;
begin
  if (Index < 0) or (Index >= FPaths.Count) then
    Exit;
  Path := FPaths[Index];
  FText.Lines.BeginUpdate;
  try
    if Path = '' then
      FText.Text := FAttribution
    else if Path = '?' then
      FText.Text := AsLines(RsAboutNoLicencesNote)
    else if FileExists(Path) then
      FText.Lines.LoadFromFile(Path)
    else
      FText.Text := AsLines(Format(RsAboutNotFound, [FList.Items[Index]]));
  finally
    FText.Lines.EndUpdate;
  end;
  FText.SelStart := 0;
end;

procedure TAboutWindow.ListChanged(Sender: TObject; User: Boolean);
begin
  ShowDocument(FList.ItemIndex);
end;

procedure TAboutWindow.OpenFolderClick(Sender: TObject);
var
  Folder: string;
begin
  Folder := LicenceDirectory;
  if Folder <> '' then
    OpenDocument(Folder);
end;

procedure TAboutWindow.CloseClick(Sender: TObject);
begin
  Close;
end;

end.
