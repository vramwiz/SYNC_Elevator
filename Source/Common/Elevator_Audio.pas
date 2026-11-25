unit Elevator_Audio;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// 映像と共通の動作時刻を使い、サンプル位置から効果音を合成する。

interface

uses AviUtl2FilterTypes, Elevator_Settings;

// ホストから借りたオブジェクト情報をもとに、要求された区間の float32 PCM をチャンネル別に渡す。
// サンプル配列はホストへの通知中に有効。無音設定ではゼロを渡し、無効な出力サイズでは False を返す。
function RenderElevatorAudio(Audio: PFILTER_PROC_AUDIO; const S: TElevatorSettings): Boolean;

implementation

uses System.Math, Elevator_Timeline;

function Tone(Frequency, Age: Double): Double; inline;
begin
  Result := Sin(2 * Pi * Frequency * Age);
end;

function Pulse(Age, Duration: Double): Double; inline;
begin
  Result := 0;
  if (Age >= 0) and (Age < Duration) then
    Result := Ease(Age / 0.007) * Sqr(1 - Age / Duration);
end;

function Motor(Age, Duration, Pitch: Double): Double;
var
  Gain: Double;
begin
  Result := 0;
  if (Age < 0) or (Age >= Duration) then Exit;
  Gain := Ease(Min(Age, Duration - Age) / Min(0.24, Duration / 2));
  Result := Gain * (0.59 * Tone(Pitch, Age) + 0.24 * Tone(Pitch * 2.02, Age) +
    0.17 * Tone(Pitch * 3.31, Age));
end;

function DoorClosingSound(Seconds, CloseAt, ClosedAt, MotorPitch: Double): Double;
var
  Age: Double;
begin
  Result := 0.2 * Motor(Seconds - CloseAt, ClosedAt - CloseAt, MotorPitch * 1.42);
  if ClosedAt <= CloseAt then Exit;
  Age := Seconds - ClosedAt;
  if (Age >= 0) and (Age < 0.11) then
    Result := Result + Pulse(Age, 0.11) * (Tone(122, Age) + 0.56 * Tone(467, Age)) * 0.23;
end;

function SampleAt(const S: TElevatorSettings; const Schedule: TElevatorSchedule;
  Seconds, Gain, MotorPitch: Double): Single;
var
  Age, Value, Pitch: Double;
begin
  Result := 0;
  if Seconds < Schedule.PressAt then Exit;
  Age := Seconds - Schedule.PressAt;
  Pitch := 690;
  if S.Scene <> esOutside then Pitch := 1030;
  if S.Era <= eeMidShowa then Pitch := Pitch * 0.59;
  Value := 0;
  if Schedule.PressButton and (Age < 0.12) then
    Value := Pulse(Age, 0.12) * (Tone(Pitch, Age) + 0.37 * Tone(Pitch * 2.13, Age)) * 0.26;
  if Schedule.StartsOpen then
    Value := Value + DoorClosingSound(Seconds, Schedule.PressAt, Schedule.EntryClosedAt, MotorPitch);
  Age := Seconds - Schedule.DepartAt;
  Value := Value + 0.21 * Motor(Age, Schedule.ArriveAt - Schedule.DepartAt, MotorPitch);

  Age := Seconds - Schedule.ArriveAt;
  if Schedule.PlayArrivalChime and (Age >= 0) and (Age < 1.15) then
  begin
    Pitch := 698.46;
    if S.Era <= eeEarlyShowa then Pitch := 523.25;
    Value := Value + Pulse(Age, 0.76) * (Tone(Pitch, Age) + 0.25 * Tone(2.81 * Pitch, Age)) * 0.37;
    Age := Age - 0.17;
    if Age >= 0 then
      Value := Value + Pulse(Age, 0.96) * (Tone(Pitch * 1.5, Age) +
        0.22 * Tone(3.73 * Pitch, Age)) * 0.28;
  end;

  Age := Seconds - Schedule.OpenAt;
  Value := Value + 0.18 * Motor(Age, Schedule.OpenEnd - Schedule.OpenAt, MotorPitch * 1.79);
  Value := Value + DoorClosingSound(Seconds, Schedule.CloseAt, Schedule.CloseEnd, MotorPitch);
  // 外側で乗り場から離れる駆動音も、映像と同じ閉扉完了時刻を起点にする。
  Value := Value + 0.21 * Motor(Seconds - Schedule.CloseEnd, Schedule.DestinationAt - Schedule.CloseEnd, MotorPitch);
  Result := EnsureRange(Value * Gain, -1.0, 1.0);
end;

function RenderElevatorAudio(Audio: PFILTER_PROC_AUDIO; const S: TElevatorSettings): Boolean;
var
  Obj: POBJECT_INFO;
  Schedule: TElevatorSchedule;
  Samples: TArray<Single>;
  I, Channel, SampleRate: Integer;
  Gain, MotorPitch, Seconds: Double;
begin
  Result := False;
  Obj := Audio^.Object_;
  if (Obj^.SampleNum <= 0) or (Obj^.SampleNum > 1000000) or
    (Obj^.ChannelNum <= 0) or (Obj^.ChannelNum > 32) then Exit;
  SetLength(Samples, Obj^.SampleNum);
  if S.Sound and (S.Values[etVolume] > 0) and (Audio^.Scene <> nil) then
  begin
    SampleRate := Audio^.Scene^.SampleRate;
    if SampleRate > 0 then
    begin
      Schedule := MakeSchedule(S);
      Gain := S.Values[etVolume] / 100;
      MotorPitch := 66;
      if S.Scene = esOutside then MotorPitch := 54;
      if S.Kind in [ekFreight, ekConstruction, ekMine] then MotorPitch := MotorPitch * 0.79;
      for I := 0 to High(Samples) do
      begin
        Seconds := (Double(Obj^.SampleIndex) + I) / SampleRate;
        Samples[I] := SampleAt(S, Schedule, Seconds, Gain, MotorPitch);
      end;
    end;
  end;
  for Channel := 0 to Obj^.ChannelNum - 1 do
    Audio^.SetSampleData(@Samples[0], Channel);
  Result := True;
end;

end.

