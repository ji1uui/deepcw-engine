# 同梱している第三者のソフトウェア / Third-party software included

本配布物には、DeepCW モールス通信のほかに次のソフトウェアを同梱しています。
いずれも MIT または MIT 系の許諾であり、AGPL-3.0-only の本アプリケーションと
ともに再配布できます。原文の許諾条項は、各配布元のものが適用されます。

This distribution includes the following software alongside the DeepCW Morse
station. All are MIT or MIT-style licensed and may be redistributed together
with this AGPL-3.0-only application. The upstream licence texts apply as
published by each project.

| ソフトウェア / software | 用途 / used for | 許諾 / licence | 入手元 / upstream |
| --- | --- | --- | --- |
| ONNX Runtime | モデルの推論 / running the model | MIT | https://github.com/microsoft/onnxruntime |
| PortAudio | 音声の入出力 / audio input and output | MIT 系 / MIT-style | https://www.portaudio.com/ |

`model.onnx` と `model.onnx.json` は DeepCW エンジンの一部であり、本リポジトリの
`LICENSE`（AGPL-3.0-only）に従います。

`model.onnx` and `model.onnx.json` are part of the DeepCW engine and follow
this repository's `LICENSE` (AGPL-3.0-only).

## 許諾条項の同梱について / on including the licence texts

**配布物を公開する際は、上記 2 つの許諾条項の全文をこのディレクトリに置いて
ください。**MIT 系の許諾は、著作権表示と許諾条項を配布物に含めることを求めて
います。本スクリプトは条項の全文を取得しないため、ここに置くのは配布する人の
責任です。

**Before publishing a distribution, place the full licence text of both of the
above in this directory.** MIT-style licences require the copyright notice and
the licence text to travel with the distribution. This script does not fetch
those texts, so putting them here is the responsibility of whoever distributes.
