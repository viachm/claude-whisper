"""Generates Claude Whisper's cue sounds: for each sound set a start cue (listening began, or it
locked), a stop cue (let go, or cancelled) and an improve cue (the improve key switched Claude's
cleanup on or off), as Resources/<set>-start.wav, <set>-stop.wav and <set>-improve.wav.
Everything is synthesised here, so the files are ours to publish.
Run with: python3 -I tools/make-sounds.py"""
import math, struct, wave, pathlib

RATE = 44100


def note(freq, length, peak, decay=28.0, attack=0.006, glide_to=None, partials=((1, 1.0), (2, 0.25))):
    """A tone with a quick attack and an exponential decay, so it never clicks. `glide_to` slides the
    pitch over the note; `partials` are (frequency multiple, level) pairs."""
    samples, phase = [], [0.0] * len(partials)
    n = int(length * RATE)
    for i in range(n):
        t = i / RATE
        f = freq if glide_to is None else freq + (glide_to - freq) * (i / n)
        envelope = min(1, t / attack) * math.exp(-t * decay)
        value = 0.0
        for k, (multiple, level) in enumerate(partials):
            phase[k] += 2 * math.pi * f * multiple / RATE
            value += level * math.sin(phase[k])
        samples.append(peak * envelope * value)
    return samples


def mix(*parts):
    """(offset in seconds, samples) pairs added together."""
    total = max(int(off * RATE) + len(s) for off, s in parts)
    out = [0.0] * total
    for off, s in parts:
        start = int(off * RATE)
        for i, v in enumerate(s):
            out[start + i] += v
    return out


def write(path, samples):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))


bell = ((1, 1.0), (2.76, 0.35), (5.4, 0.12))
pure = ((1, 1.0),)
tick = ((1, 1.0), (1.5, 0.3))
SETS = {
    # Two bright blips, rising to start and falling to stop; improve is a quick high sparkle.
    "chime": (mix((0, note(784, 0.16, 0.32)), (0.07, note(1175, 0.2, 0.32))),
              mix((0, note(1175, 0.16, 0.28)), (0.07, note(784, 0.22, 0.28))),
              mix((0, note(1568, 0.1, 0.22)), (0.05, note(2093, 0.14, 0.22)))),
    # Lower, rounder and longer: a gentle major third; improve is one soft high note.
    "soft": (mix((0, note(523, 0.3, 0.3, decay=12, attack=0.02, partials=pure)),
                 (0.09, note(659, 0.35, 0.3, decay=12, attack=0.02, partials=pure))),
             mix((0, note(659, 0.3, 0.27, decay=12, attack=0.02, partials=pure)),
                 (0.09, note(523, 0.4, 0.27, decay=12, attack=0.02, partials=pure))),
             note(784, 0.28, 0.24, decay=14, attack=0.02, partials=pure)),
    # A short tick, higher to start, lower to stop; improve is a quick double tick.
    "click": (note(2000, 0.05, 0.4, decay=90, attack=0.001, partials=tick),
              note(1300, 0.05, 0.4, decay=90, attack=0.001, partials=tick),
              mix((0, note(2400, 0.04, 0.3, decay=110, attack=0.001, partials=tick)),
                  (0.06, note(2400, 0.04, 0.3, decay=110, attack=0.001, partials=tick)))),
    # One note that slides up to start and down to stop; improve is a short high hop.
    "bubble": (note(420, 0.14, 0.38, decay=18, glide_to=980, partials=pure),
               note(980, 0.14, 0.34, decay=18, glide_to=420, partials=pure),
               note(900, 0.09, 0.3, decay=24, glide_to=1400, partials=pure)),
    # A small glass bell: one strike to start, a lower one to stop; improve is a high, quiet one.
    "glass": (note(1568, 0.45, 0.22, decay=9, attack=0.002, partials=bell),
              note(1047, 0.45, 0.22, decay=9, attack=0.002, partials=bell),
              note(2349, 0.3, 0.16, decay=12, attack=0.002, partials=bell)),
}

res = pathlib.Path(__file__).resolve().parent.parent / "Resources"
for name, (start, stop, improve) in SETS.items():
    write(res / f"{name}-start.wav", start)
    write(res / f"{name}-stop.wav", stop)
    write(res / f"{name}-improve.wav", improve)
print("wrote", ", ".join(SETS), "start/stop/improve cues to", res)
