---
description: Windows / macOS、x86_64 / ARM64の差異管理。Platform Boundary、Platform Matrix、ファイルシステムとUnicode、ネイティブライブラリ、オーディオデバイス、LCLのUI差異、CI Matrix、パッケージング。
when_to_use: 条件コンパイル、DLL / dylib、パス処理、DPI、IME、ダークモード、署名、notarization、ビルド設定、ARM64対応に触れるとき。
paths:
  - "**/platform/**"
  - "**/*.lpi"
  - "**/*.lpk"
  - "**/*.lpr"
  - "**/*win*.pas"
  - "**/*mswindows*"
  - "**/*mac*.pas"
  - "**/*darwin*"
  - "**/*cocoa*"
  - "**/*.plist"
  - "**/*.iss"
  - "**/Makefile"
user-invocable: true
---

# Cross-platform Engineering

## Principle

> OS依存性を排除するのではなく、OS依存性の存在箇所を限定し、検証可能にする。

Functional equivalenceを重視し、Pixel equivalenceを目的にしない。

## Platform Boundary

OS差分を各unitへ散在させない。

推奨インターフェース:
IAudioDevice / IHighResolutionTimer / ISharedLibrary / IFileSystemService /
ISystemInfo / IThreadPriorityService / INotificationService

条件コンパイルが増える場合はPlatform Adapterへ集約する。

## Platform Matrix

OSとCPU architectureを同一概念として扱わない。少なくとも4軸を別々に認識する。

- Windows x86_64
- Windows ARM64
- macOS x86_64
- macOS ARM64

## Filesystem / Unicode

separator / case sensitivity / Unicode normalization / forbidden characters /
filename encoding / long path / temp・config・user-dataディレクトリ / line endings

## Native Libraries

- Windows: DLL / search path / calling convention
- macOS: dylib / @rpath / @loader_path / architecture / signing

## Audio

sample rate negotiation / buffer size / exclusive・shared差 / device hot-plug /
default device change / suspend・resume / device loss / latency / clock drift

## LCL / UX Differences

DPI・Retina / font metrics / menu conventions / Ctrl・Command / focus /
dialog behavior / resize / IME / dark mode / accessibility

## CI Matrix

cross-platform verifiedを名乗るには対象matrixの実行結果が必要。
実行不能なplatformは NOT VERIFIED とする。現在の実行OSでの成功をもって全platformの成功としない。

## Packaging

- Windows: installer / DLL deployment / signing / Defender interaction
- macOS: .app bundle / dylib placement / entitlements / microphone permission / code signing / notarization / Gatekeeper

## Definition of Done

- OS依存コードが境界化されている
- platform-specific behaviorを文書化している
- 少なくともtarget matrixのBuild結果を把握している
- Audio / Device / UI / Packaging差異を必要に応じて検証している
