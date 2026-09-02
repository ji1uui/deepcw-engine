# deepcw-engine

This repository contains the [DeepCW](https://github.com/e04/web-deep-cw-decoder) model and a minimal example.

## Preparing WAV Audio

The examples can read and resample ordinary PCM WAV files, but preparing the audio with
`ffmpeg` makes the input explicit and repeatable:

```bash
ffmpeg -i input.wav -ac 1 -ar 3200 -sample_fmt s16 target.wav
```

The sample rate shown above matches the current `model.onnx.json`. If the metadata changes,
use the `sample_rate` value from that file.

## Python Example

Directory: `examples/python`

Install dependencies:

```bash
cd examples/python
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Run the decoder:

```bash
python decode_morse.py \
  --model ../../model.onnx \
  --metadata ../../model.onnx.json \
  --wav test.wav
```

## Node.js Example

Directory: `examples/nodejs`

Install dependencies:

```bash
cd examples/nodejs
npm install
```

Run the decoder:

```bash
npm run decode -- \
  --model ../../model.onnx \
  --metadata ../../model.onnx.json \
  --wav test.wav
```

## Lazarus Example

Directory: `examples/lazarus`

A Free Pascal / Lazarus Morse station that keys CW on transmit and decodes it
with this model on receive, plus two console tools built from the same units.
ONNX Runtime and PortAudio are loaded at run time, so nothing extra is linked
at build time.

```bash
cd examples/lazarus
lazbuild app/deepcw_station.lpi
./app/deepcw_station
```

Decode a single file from the console:

```bash
lazbuild cli/decode_morse.lpi
./cli/decode_morse \
  --model ../../model.onnx \
  --metadata ../../model.onnx.json \
  --wav test.wav
```

See `examples/lazarus/README.md` for the library requirements and a tour of the
units.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
