# Lazarus Morse Station

A Free Pascal / Lazarus application that keys Morse code on transmit and
decodes it with the DeepCW ONNX model on receive, plus two console tools that
share the same units.

```
lazarus/
├── src/    reusable units: metadata, WAV, DSP, ONNX Runtime, decoder, Morse, audio
├── app/    deepcw_station  - the GUI station (LCL)
│        waterfall_probe - exercise the waterfall control without a display
└── cli/    decode_morse    - decode one WAV file, like the Python and Node.js examples
         cw_loopback     - key six messages, decode them back, report the score
         cw_stream       - feed a WAV in chunks, watch confirmed text grow
         cw_tune         - measure the tuning path: pitch, translation, bandwidth
         cw_devices      - list input devices and check the PortAudio ABI
    tools/  make_bundle.sh - assemble a distribution that needs no installs
```

## What it does

**送信 (transmit)** turns text into a keyed sidetone. Character speed and
effective speed are separate, so Farnsworth spacing works the way it does on a
training oscillator: characters stay crisp at 20 WPM while the gaps stretch to
an overall 10 WPM. Every edge gets a raised-cosine ramp, which keeps the
transmission free of key clicks. Optional white noise makes a realistic
practice signal. The audio can be played through the sound card, saved as a
WAV, or fed straight back into the decoder with 自己デコード確認.

**受信 (receive)** decodes either a WAV file or live sound card input. Live
reception decodes a sliding window every few seconds and stitches the results
together; recordings longer than the model's 20 second limit are split into
overlapping windows automatically. The spectrogram the model actually sees is
drawn underneath the transcript.

**設定 (settings)** points at the model, the metadata and — if the automatic
search does not find them — the ONNX Runtime and PortAudio shared libraries.
Settings are remembered between runs.

## Requirements

* Free Pascal 3.2 or newer and Lazarus 2.2 or newer (`lazbuild` is enough; the
  IDE is not required).
* **ONNX Runtime**, loaded at run time. Any 1.x release works.
* **PortAudio** (optional). Without it the application still decodes WAV files
  and saves transmissions; only the sound card paths are disabled.

Neither library is linked at build time, so a build succeeds without them and
the application explains what is missing on the 設定 tab.

### Getting the libraries

| Platform | ONNX Runtime | PortAudio |
| --- | --- | --- |
| Debian / Ubuntu | download `onnxruntime-linux-x64-*.tgz` from the [ONNX Runtime releases](https://github.com/microsoft/onnxruntime/releases), or reuse `libonnxruntime.so` from a `pip install onnxruntime` | `apt install libportaudio2` |
| macOS | `brew install onnxruntime` | `brew install portaudio` |
| Windows | `onnxruntime.dll` from the same releases page | `portaudio_x64.dll` |

Put the library next to the executable, on the system search path, or name it
explicitly:

```bash
export DEEPCW_ONNXRUNTIME=/path/to/libonnxruntime.so
export DEEPCW_PORTAUDIO=/path/to/libportaudio.so.2
```

## Building

```bash
cd lazarus
lazbuild app/deepcw_station.lpi
lazbuild cli/decode_morse.lpi
lazbuild cli/cw_loopback.lpi
lazbuild cli/cw_stream.lpi
lazbuild cli/cw_tune.lpi
lazbuild cli/cw_devices.lpi
lazbuild app/waterfall_probe.lpi
```

Then run the station:

```bash
./app/deepcw_station
```

It looks for `model.onnx` and `model.onnx.json` next to the executable first
and then up to two directories above it, which is where they live in this
repository, so a build from a clean checkout starts up ready to use.

## Console tools

Decode a file, exactly like `examples/python` and `examples/nodejs`:

```bash
./cli/decode_morse --wav test.wav
```

The model and metadata are found relative to the executable, so both tools work
from any working directory. Pass `--model` and `--metadata` to override them.

Unlike the other two examples this one accepts recordings of any length: past
20 seconds it slides a 15 second window across the audio and merges the
transcripts.

Check that a build and its ONNX Runtime are healthy without a sound card:

```bash
./cli/cw_loopback
```

It keys six messages at different speeds, pitches and noise levels, decodes
each one back and exits non-zero if any of them differs from what was sent.

Check the tuning path — the frequency translation that makes a signal outside
the model's 400-1200 Hz passband readable:

```bash
./cli/cw_tune --tests shift,image,bandwidth,stream
```

Each test prints character error rates, so a change that makes tuning worse
shows up as a number rather than as a feeling. `--tests sweep` re-derives the
pitch that translation aims at.

Check the waterfall control itself, including on a machine with no display:

```bash
xvfb-run -a ./app/waterfall_probe /tmp
```

It creates the control for real, feeds it two signals, applies clicks, wheel
events and key presses, and writes the painted result out as PNG files.

Check the sound card, and the PortAudio structure layout that reading it
depends on:

```bash
./cli/cw_devices --abi --listen 2
```

The PortAudio structures are read as the C layout they are, and the padding
differs between platforms; `--abi` compares every field offset against the
rule a C compiler follows, which is the first thing to run after porting to a
new platform. `--listen` records briefly and reports the level that arrived,
which is how the silence threshold gets chosen from measurement.

## Making a distribution

```bash
DEEPCW_ONNXRUNTIME=/path/to/libonnxruntime.so \
DEEPCW_PORTAUDIO=/path/to/libportaudio.so.2 \
tools/make_bundle.sh
```

This stages the executables, the model, both shared libraries and the licence
files into `dist/deepcw-station-<platform>-<arch>/`. Everything is loaded from
beside the executable first, so the result runs on a machine with neither
library installed. Read `dist-notes/THIRD-PARTY-NOTICES.md` before publishing
one: the MIT-style licences require their texts to travel with the files, and
the script does not fetch them for you.

## The units

| Unit | Responsibility |
| --- | --- |
| `DeepCW.Types` | shared array types and the `EDeepCW` exception |
| `DeepCW.Metadata` | reads and validates `model.onnx.json` |
| `DeepCW.Wave` | RIFF/WAVE reading and writing, linear resampling |
| `DeepCW.Dsp` | radix-2 FFT, the model's STFT, an anti-alias low-pass |
| `DeepCW.Tuner` | frequency translation onto the pitch the model reads, band-pass, and the one place audio is prepared for the model |
| `DeepCW.Onnx` | ONNX Runtime C API binding, loaded at run time |
| `DeepCW.Decoder` | spectrogram to text, greedy CTC, window stitching |
| `DeepCW.Morse` | the code table, PARIS and Farnsworth timing, tone synthesis |
| `DeepCW.Stream` | splits a live stream into confirmed and provisional text |
| `DeepCW.Audio` | PortAudio capture and playback, device enumeration, loaded at run time |

Only `DeepCW.Audio` and the GUI depend on PortAudio, and only `DeepCW.Onnx`
depends on the runtime, so the DSP and Morse units can be reused on their own.

### Matching the reference implementations

`TDeepCWDecoder.DecodeSamples` produces the same text as
`examples/python/decode_morse.py` for the same input: identical reflect
padding, periodic Hann window, bin selection and `log1p` compression, and the
same linear resampler. The additions in this example — window stitching for
long audio and the optional anti-alias filter on the receive tab — sit outside
that path rather than changing it.

### Notes on the ONNX binding

`OrtGetApiBase` is the only symbol the runtime exports; everything else arrives
in a struct of function pointers. That struct is append-only across releases,
so `DeepCW.Onnx` declares the leading entries by position, types the ones it
calls and leaves the rest opaque. **The field order in `TOrtApi` is the ABI**:
entries must never be reordered or removed, only appended.

## Known limits

* The model alphabet is A-Z, 0-9, `,` `.` `?` `/` and space. Other characters
  are dropped before keying, since the decoder could not return them anyway.
* Audio shorter than five seconds is rejected by the model. The GUI pads short
  transmissions with silence before a self-decode; the console decoder reports
  the limit instead of guessing.
* Live reception decodes a whole window at a time, so text appears in bursts
  rather than character by character.

## A note on the source comments

Every comment in `src/`, `app/` and `cli/` is written in Japanese first and
English second, so the code reads the same way for either audience.

## License

AGPL-3.0-only, the same as the rest of this repository.
