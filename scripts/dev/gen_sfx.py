#!/usr/bin/env python3
"""Regenerate the self-made (CC0) sound cues in assets/sfx/.

Pure-stdlib synth (sine + harmonics + envelopes) tuned to the calm "limpid" feel.
Run from the project root:  python3 scripts/dev/gen_sfx.py
Then reimport in Godot:     godot --headless --path . --import
Tweak freqs / amps / decays below to taste, or swap the .wav files for recorded SFX.
"""
import wave, struct, math, random, os

SR = 44100
random.seed(7)
OUT = "assets/sfx"


def _wave(samples, path):
    with wave.open(path, "w") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        frames = bytearray()
        for s in samples:
            v = max(-1.0, min(1.0, s))
            frames += struct.pack("<h", int(v * 32000))
        w.writeframes(frames)


def note(freq, dur, amp=0.3, decay=12.0, harmonics=((1, 1.0), (2, 0.25)), noise=0.0):
    n = int(SR * dur); out = []
    atk = max(1, int(SR * 0.004)); rel = max(1, int(SR * 0.012))
    for i in range(n):
        t = i / SR
        e = math.exp(-t * decay)
        if i < atk: e *= i / atk
        if i > n - rel: e *= max(0.0, (n - i) / rel)
        v = 0.0
        for mult, ha in harmonics:
            v += ha * math.sin(2 * math.pi * freq * mult * t)
        if noise > 0:
            v += noise * (random.random() * 2 - 1) * math.exp(-t * 60)
        out.append(amp * e * v)
    return out


def seq(notes):
    out = []
    for ns in notes:
        out += ns
    return out


C5, E5, G5, C6 = 523.25, 659.25, 783.99, 1046.5
A4, A3, E4, G4, D4 = 440.0, 220.0, 329.63, 392.0, 293.66


def main():
    os.makedirs(OUT, exist_ok=True)
    _wave(note(700, 0.075, 0.32, 55, ((1, 1.0), (2, 0.3)), noise=0.18), f"{OUT}/move.wav")
    _wave([a + b for a, b in zip(
        note(300, 0.13, 0.34, 32, ((1, 1.0), (2, 0.4)), noise=0.22),
        note(150, 0.13, 0.18, 28))], f"{OUT}/capture.wav")
    _wave(seq([note(C5, 0.085, 0.30, 18), note(E5, 0.085, 0.30, 18),
               note(G5, 0.16, 0.30, 14, ((1, 1.0), (2, 0.35)))]), f"{OUT}/best.wav")
    _wave(note(A4, 0.18, 0.26, 11, ((1, 1.0), (2, 0.2))), f"{OUT}/decent.wav")
    _wave(seq([note(G4, 0.14, 0.27, 9, ((1, 1.0), (0.5, 0.3))),
               note(D4, 0.22, 0.27, 7, ((1, 1.0), (0.5, 0.35)))]), f"{OUT}/blunder.wav")
    _wave(seq([note(C5, 0.09, 0.30, 15), note(E5, 0.09, 0.30, 15), note(G5, 0.09, 0.30, 15),
               note(C6, 0.26, 0.32, 11, ((1, 1.0), (2, 0.4)))]), f"{OUT}/win.wav")
    _wave([a + b for a, b in zip(
        note(A3, 0.5, 0.20, 4.5, ((1, 1.0), (2, 0.2))),
        note(E4, 0.5, 0.12, 4.5))], f"{OUT}/end.wav")
    print("regenerated cues in", OUT)


if __name__ == "__main__":
    main()
