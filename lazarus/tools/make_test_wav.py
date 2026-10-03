"""試験用のモールス音を WAV に書きます（標準ライブラリだけ）。

配布物の試験（付録 CO）で、**配布物の中の道具が、同梱した部品だけで読める**
ことを確かめるための音です。numpy を要らないのは、Windows の CI の Python に
入っているとは限らないためです。

Writes a Morse test tone to a WAV file using only the standard library.
Used by the package test (appendix CO) to show that **the tools inside the
package read it with nothing but what is bundled.** No numpy, since the
Windows CI's Python is not guaranteed to have it.

usage: python make_test_wav.py out.wav [TEXT]
"""
import math
import struct
import sys
import wave

MORSE = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.', 'F': '..-.',
    'G': '--.', 'H': '....', 'I': '..', 'J': '.---', 'K': '-.-', 'L': '.-..',
    'M': '--', 'N': '-.', 'O': '---', 'P': '.--.', 'Q': '--.-', 'R': '.-.',
    'S': '...', 'T': '-', 'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-',
    'Y': '-.--', 'Z': '--..', '0': '-----', '1': '.----', '2': '..---',
    '3': '...--', '4': '....-', '5': '.....', '6': '-....', '7': '--...',
    '8': '---..', '9': '----.',
}
RATE, WPM, TONE = 8000, 20, 700.0


def keying(text):
    unit = int(round(1.2 / WPM * RATE))
    env = [0.0] * int(0.3 * RATE)
    for word in text.split():
        for ch in word:
            for sym in MORSE[ch]:
                env += [1.0] * ((3 if sym == '-' else 1) * unit) + [0.0] * unit
            env += [0.0] * (2 * unit)
        env += [0.0] * (4 * unit)
    env += [0.0] * int(0.5 * RATE)
    # 5 ms の立ち上がり。クリックを避けます / 5 ms edges, avoiding clicks
    ramp, level, out = int(0.005 * RATE), 0.0, []
    for v in env:
        level += (v - level) / ramp
        out.append(level)
    return out


def main():
    path = sys.argv[1]
    text = sys.argv[2] if len(sys.argv) > 2 else 'CQ CQ DE JA1ABC JA1ABC K'
    frames = bytearray()
    for n, e in enumerate(keying(text)):
        x = 0.5 * e * math.sin(2 * math.pi * TONE * n / RATE)
        frames += struct.pack('<h', int(x * 32000))
    with wave.open(path, 'wb') as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(bytes(frames))


if __name__ == '__main__':
    main()
