library SYNC_Elevator;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

// エレベーター演出の AviUtl2 DLL 境界。登録と終了の入口を公開する。
// Delphi 例外は C コールバックの外へ漏らさない。

{$ALIGN 8}

uses
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  PluginFilterTable in 'Source\Lib\FilterTable\PluginFilterTable.pas',
  Elevator_Settings in 'Source\Common\Elevator_Settings.pas',
  Elevator_Timeline in 'Source\Common\Elevator_Timeline.pas',
  Elevator_Canvas in 'Source\Common\Elevator_Canvas.pas',
  Elevator_Glyphs in 'Source\Common\Elevator_Glyphs.pas',
  Elevator_Scenery in 'Source\Common\Elevator_Scenery.pas',
  Elevator_Structure in 'Source\Common\Elevator_Structure.pas',
  Elevator_Controls in 'Source\Common\Elevator_Controls.pas',
  Elevator_Framebuffer in 'Source\Common\Elevator_Framebuffer.pas',
  Elevator_Renderer in 'Source\Common\Elevator_Renderer.pas',
  Elevator_Audio in 'Source\Common\Elevator_Audio.pas',
  Elevator_Parameters in 'Source\Plugin\Filter\Elevator_Parameters.pas',
  SYNC_Elevator_FilterPlugin in 'Source\Plugin\Filter\SYNC_Elevator_FilterPlugin.pas';

{$R *.res}

// ホストのバージョンを確認し、DLL 所有の登録テーブルを初期化する。
// 非対応バージョンと初期化失敗は 0 を返す。
function InitializePlugin(Version: Cardinal): Byte; cdecl;
begin
  Result := 0;
  try
    if Version < ELEVATOR_REQUIRED_VERSION then Exit;
    GetElevatorFilterTable;
    Result := 1;
  except
    // 初期化失敗は戻り値でホストへ伝える。
  end;
end;

// 描画資源はホストのfunc_destroyでエフェクトごとに解放する。
procedure UninitializePlugin; cdecl;
begin
end;

// 公式 SDK 形式の最低対応バージョン番号を返す。
function RequiredVersion: Cardinal; cdecl;
begin
  Result := ELEVATOR_REQUIRED_VERSION;
end;

// DLL 所有の登録テーブルを返す。取得失敗時は nil を返す。
function GetFilterPluginTable: PFILTER_PLUGIN_TABLE; cdecl;
begin
  Result := nil;
  try
    Result := GetElevatorFilterTable;
  except
    // 登録失敗時はテーブルを返さずホスト側へ判断を委ねる。
  end;
end;

exports
  RequiredVersion name 'RequiredVersion',
  InitializePlugin name 'InitializePlugin',
  UninitializePlugin name 'UninitializePlugin',
  GetFilterPluginTable name 'GetFilterPluginTable';

begin
end.
