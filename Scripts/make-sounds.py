#!/usr/bin/env python3
"""Synthesise the app's sound set.

Run from anywhere:

    python3 Scripts/make-sounds.py

Checked in because the .caf files in App/Resources/Sounds are the only copies
of these sounds anywhere. A binary asset whose recipe was lost is an asset
nobody can adjust: the next person who wants the capture a shade drier has to
either accept it or start from silence. Every parameter that shapes a sound is
below, and every run is byte-for-byte reproducible (each hit draws its noise
from its own seeded generator).

## The register

The app's sounds have to survive a forty-move game played under a running
clock, on a phone, in a room with other things happening. That rules out
almost everything a synthesiser is good at. What is left is a description of a
physical event: a wooden piece meeting a felt-backed board.

So each sound is a *contact*, modelled the way a contact actually sounds — a
few milliseconds of filtered noise where the two surfaces meet, exciting a
handful of damped low-mid partials that die inside a tenth of a second. No
sound here is a note, none of them harmonise, and none of them resolve.
Anything with a pitch you could hum becomes a tune by the tenth move, and a
tune under a chess clock is an arcade.

The budget is the same one the haptics live under, and for the same reason: an
event that both buzzes and chimes on every move is how an app starts feeling
defective. Two of the eight sanctioned haptic events make no sound at all, and
SILENT_EVENTS below says which and why.

## Where the family sits

Every partial is between 196 and 880 Hz, which is lower than it reads written
down and higher than "wooden" suggests on its own. The floor is the phone. The
speaker in an iPhone has very little output below about 600 Hz, so a knock
built around a 200 Hz body — the obvious first answer to "make it sound like
wood" — is a lovely sound on headphones and nothing at all in the hand. The
ceiling is the register: above roughly 4 kHz is where a blip lives, and there
is none of it here.

That leaves a narrow window, and the only way to know a sound is inside it is
to measure. Each file is run through a two-pole high-pass at SPEAKER_HZ, which
is a crude stand-in for the speaker, and what comes out the far side is the
level printed as `speaker`. Absolute values there mean little; the spread does.
A set where one sound is 20 dB below the others is a set with a sound nobody
will ever hear, so MAX_SPREAD_DB is checked and the quiet end of the range is
where the deliberately quiet sounds are meant to sit — not where a sound ended
up by accident.

## Levels

Peaks are set per sound rather than normalised to a common ceiling, because
these are never played in isolation and are never the thing being listened to.
A capture is the loudest at −6 dBFS because it is the one board event a player
cannot afford to miss; a move sits just under it; a refusal is the quietest,
since it is the board reporting that nothing happened and it arrives with a
tap and a shake already. Nothing is above −6: these play under a running clock,
and headroom is what keeps them under it rather than over it.

## Format

16-bit PCM in a CAF container, 44.1 kHz mono, uncompressed. The whole set is
about a hundred kilobytes next to a 71 MB bundled NNUE, so ADPCM's quantisation
noise — exactly the artefact that shows up on quiet, sparse material like this
— would be bought with nothing.
"""

from __future__ import annotations

import math
import shutil
import subprocess
import sys
import tempfile
import textwrap
import wave
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

SAMPLE_RATE = 44_100
OUTPUT_DIR = Path(__file__).resolve().parent.parent / "App" / "Resources" / "Sounds"

# Every partial and noise burst is quoted as the time it takes to fall 60 dB,
# which is a length you can hear, rather than as a time constant, which is not.
DECAY_TO_60_DB = math.log(1000.0)

# The last few milliseconds are already 55 dB down, but a buffer that ends on a
# non-zero sample clicks on some hardware and not others, which is the worst
# kind of defect to chase.
FADE_OUT_MS = 8.0

# A damped sine started from a zero crossing has more area under its first half
# cycle than under its second, so a synthesised knock carries a sub-audible
# offset that a recorded one does not — a microphone is AC-coupled and this is
# not. Two poles at 32 Hz put that back: inaudible content removed, and the
# lowest partial in the set (196 Hz) is down a fifth of a decibel before the
# peak normalisation that follows takes even that back.
HIGHPASS_HZ = 32.0
HIGHPASS_POLES = 2

# A phone speaker, roughly. Two poles at 600 Hz is not a measurement of any
# particular handset; it is enough of one to tell a sound that survives the
# hardware from a sound that does not.
SPEAKER_HZ = 600.0
SPEAKER_POLES = 2

# How far the quietest sound may sit below the loudest once the speaker has had
# its way. The spread is a design — a capture is meant to be the loudest thing
# here and a refusal the quietest — so this is a bound on the spread, not a
# floor under each sound.
MAX_SPREAD_DB = 12.0


@dataclass(frozen=True)
class Partial:
    """One damped sine: the body ringing after the contact."""

    freq: float
    decay_ms: float
    amp: float


@dataclass(frozen=True)
class Noise:
    """The contact itself — broadband, band-limited, and over almost at once."""

    lo: float
    hi: float
    decay_ms: float
    amp: float


@dataclass(frozen=True)
class Hit:
    """A single contact at a point in time, and the body it excites."""

    noise: Noise
    partials: tuple[Partial, ...]
    at_ms: float = 0.0
    gain: float = 1.0
    # Partials start at a zero crossing, so the attack is shaping loudness, not
    # preventing a discontinuity. Two milliseconds reads as a hard object; the
    # game-end settle uses more so that it arrives rather than knocks.
    attack_ms: float = 2.0
    seed: int = 0


@dataclass(frozen=True)
class SoundSpec:
    """One file, and the reasoning that fixes its shape."""

    name: str
    event: str
    peak_dbfs: float
    hits: tuple[Hit, ...]
    note: str


SOUNDS: tuple[SoundSpec, ...] = (
    SoundSpec(
        name="move",
        event="legal drop",
        peak_dbfs=-7.0,
        note=(
            "The anchor of the family: one contact, a 330 Hz body, gone in a "
            "tenth of a second. Everything else is heard relative to this."
        ),
        hits=(
            Hit(
                noise=Noise(lo=1100, hi=3800, decay_ms=6, amp=0.55),
                partials=(
                    Partial(freq=330, decay_ms=80, amp=1.00),
                    Partial(freq=511, decay_ms=55, amp=0.50),
                    Partial(freq=749, decay_ms=32, amp=0.28),
                ),
                seed=11,
            ),
        ),
    ),
    SoundSpec(
        name="capture",
        event="capture",
        peak_dbfs=-6.0,
        note=(
            "Two contacts 34 ms apart — the piece being dislodged, then the "
            "one that took it settling. A fifth lower than a move and with "
            "more grain in the transient, which is what makes it read as a "
            "capture rather than as a louder move. It must not be louder: "
            "most captures in a game are the opponent's."
        ),
        hits=(
            Hit(
                noise=Noise(lo=800, hi=3000, decay_ms=10, amp=0.62),
                partials=(
                    Partial(freq=262, decay_ms=120, amp=1.00),
                    Partial(freq=417, decay_ms=75, amp=0.62),
                    Partial(freq=623, decay_ms=40, amp=0.30),
                ),
                seed=22,
            ),
            Hit(
                noise=Noise(lo=1200, hi=3600, decay_ms=5, amp=0.45),
                partials=(
                    Partial(freq=311, decay_ms=60, amp=1.00),
                    Partial(freq=466, decay_ms=38, amp=0.40),
                ),
                at_ms=34,
                gain=0.45,
                seed=23,
            ),
        ),
    ),
    SoundSpec(
        name="check",
        event="check delivered",
        peak_dbfs=-6.5,
        note=(
            "Tension without triumph. The 622/659 Hz pair beats at 37 Hz, "
            "heard as a rattle in the body of an otherwise ordinary knock, and "
            "the two of them outlast the fundamental so the rattle is what is "
            "left ringing. Check is as likely to be against the user as for "
            "them, so it is allowed to be unsettling and never a fanfare."
        ),
        hits=(
            Hit(
                noise=Noise(lo=1200, hi=4200, decay_ms=6, amp=0.50),
                partials=(
                    Partial(freq=392, decay_ms=105, amp=1.00),
                    Partial(freq=622, decay_ms=130, amp=0.34),
                    Partial(freq=659, decay_ms=130, amp=0.32),
                    Partial(freq=880, decay_ms=35, amp=0.14),
                ),
                seed=33,
            ),
        ),
    ),
    SoundSpec(
        name="refusal",
        event="illegal drop",
        peak_dbfs=-10.0,
        note=(
            "Dead and muffled — nothing landed, so the board never rang. The "
            "transient is band-limited an octave below every other sound here, "
            "which is what dull has to mean when the alternative is inaudible. "
            "It is the quietest thing in the set through a speaker, and that "
            "is the intent: it arrives with a rigid tap and a shake, and a "
            "refusal that is also the loudest thing the app does is scolding."
        ),
        hits=(
            Hit(
                noise=Noise(lo=500, hi=2200, decay_ms=5, amp=0.60),
                partials=(
                    Partial(freq=262, decay_ms=45, amp=1.00),
                    Partial(freq=349, decay_ms=26, amp=0.40),
                ),
                seed=44,
            ),
        ),
    ),
    SoundSpec(
        name="game-end",
        event="game end, any result",
        peak_dbfs=-8.0,
        note=(
            "One sound for a win, a loss and a draw. The result is on screen "
            "in words; a sound that resolved happily for a win would have to "
            "resolve unhappily for a loss, and an app that sighs at somebody "
            "who has just lost is a mascot with the lights off. A low box "
            "closing: near-harmonic partials, no click on the front, and 300 "
            "ms of settle — the only sound here long enough to be described "
            "as ending rather than happening."
        ),
        hits=(
            Hit(
                noise=Noise(lo=500, hi=2200, decay_ms=12, amp=0.30),
                partials=(
                    Partial(freq=196, decay_ms=300, amp=1.00),
                    Partial(freq=392, decay_ms=190, amp=0.60),
                    Partial(freq=589, decay_ms=110, amp=0.34),
                    Partial(freq=785, decay_ms=55, amp=0.16),
                ),
                attack_ms=9.0,
                seed=55,
            ),
        ),
    ),
    SoundSpec(
        name="clock-low",
        event="clock crosses ten seconds",
        peak_dbfs=-10.0,
        note=(
            "Two soft knocks 130 ms apart, the highest-pitched thing in the "
            "set so it carries across a room without being sharp. Deliberately "
            "not a board sound: nothing landed, and a pair reads as a signal "
            "where a single knock would read as a move. Quiet, because the "
            "point is to be noticed without startling somebody into the "
            "blunder the warning exists to prevent."
        ),
        hits=(
            Hit(
                noise=Noise(lo=1000, hi=2600, decay_ms=4, amp=0.25),
                partials=(
                    Partial(freq=523, decay_ms=50, amp=1.00),
                    Partial(freq=803, decay_ms=28, amp=0.30),
                ),
                seed=66,
            ),
            Hit(
                noise=Noise(lo=1000, hi=2600, decay_ms=4, amp=0.25),
                partials=(
                    Partial(freq=523, decay_ms=50, amp=1.00),
                    Partial(freq=803, decay_ms=28, amp=0.30),
                ),
                at_ms=130,
                gain=0.85,
                seed=67,
            ),
        ),
    ),
)

# Sanctioned haptic events with no sound of their own, and the reason. Kept
# here rather than in a commit message because the absences are the design.
SILENT_EVENTS = {
    "piece lifted": (
        "Doubles the sounds per move for an event the user is already "
        "watching their own finger perform."
    ),
    "checklist step complete": (
        "In guided mode a step completes on the same gesture that lands a "
        "move, so it would arrive as a second sound on one action."
    ),
}


def tau(decay_ms: float) -> float:
    """Time constant for a decay quoted as its 60 dB fall time."""
    return (decay_ms / 1000.0) / DECAY_TO_60_DB


def highpass(buffer: np.ndarray, hz: float, poles: int) -> np.ndarray:
    """One-pole high-pass, applied as many times as there are poles.

    Recursive rather than a spectral mask because a zero-phase filter smears
    energy backwards across the buffer edge, and the one place these files must
    be exactly silent is their first sample.
    """
    dt = 1.0 / SAMPLE_RATE
    rc = 1.0 / (2 * np.pi * hz)
    alpha = rc / (rc + dt)

    out = buffer
    for _ in range(poles):
        source = out
        out = np.zeros_like(source)
        for n in range(1, len(source)):
            out[n] = alpha * (out[n - 1] + source[n] - source[n - 1])
    return out


def band_gain(freqs: np.ndarray, lo: float, hi: float) -> np.ndarray:
    """Raised-cosine band, an octave of skirt either side.

    Brick walls ring: a rectangular window in the frequency domain is a sinc in
    the time domain, which smears a 7 ms transient into a chirp.
    """
    gain = np.zeros_like(freqs)
    lower = (freqs >= lo / 2) & (freqs < lo)
    gain[lower] = 0.5 - 0.5 * np.cos(np.pi * (freqs[lower] - lo / 2) / (lo / 2))
    gain[(freqs >= lo) & (freqs <= hi)] = 1.0
    upper = (freqs > hi) & (freqs <= hi * 2)
    gain[upper] = 0.5 + 0.5 * np.cos(np.pi * (freqs[upper] - hi) / hi)
    return gain


def band_noise(count: int, lo: float, hi: float, seed: int) -> np.ndarray:
    """Band-limited noise. The DC bin is zeroed by construction."""
    rng = np.random.default_rng(seed)
    spectrum = np.fft.rfft(rng.standard_normal(count))
    freqs = np.fft.rfftfreq(count, 1.0 / SAMPLE_RATE)
    shaped = np.fft.irfft(spectrum * band_gain(freqs, lo, hi), count)
    peak = np.max(np.abs(shaped))
    return shaped / peak if peak > 0 else shaped


def hit_length_ms(hit: Hit) -> float:
    return hit.at_ms + max(p.decay_ms for p in hit.partials)


def render(spec: SoundSpec) -> np.ndarray:
    """Mix a spec down to a float buffer peaking at its target level."""
    length_ms = max(hit_length_ms(h) for h in spec.hits) + FADE_OUT_MS
    total = int(round(length_ms / 1000.0 * SAMPLE_RATE))
    buffer = np.zeros(total, dtype=np.float64)

    for hit in spec.hits:
        start = int(round(hit.at_ms / 1000.0 * SAMPLE_RATE))
        count = total - start
        t = np.arange(count) / SAMPLE_RATE

        body = np.zeros(count)
        for partial in hit.partials:
            body += partial.amp * np.sin(2 * np.pi * partial.freq * t) * np.exp(-t / tau(partial.decay_ms))
        body *= 1.0 - np.exp(-t / (hit.attack_ms / 1000.0 / 3.0))

        noise = band_noise(count, hit.noise.lo, hit.noise.hi, hit.seed)
        noise *= hit.noise.amp * np.exp(-t / tau(hit.noise.decay_ms))
        # A fifth of the body's attack: the contact is the fastest thing in the
        # sound, and a 2 ms ramp over a 7 ms burst removes most of what makes it
        # sound like wood rather than a tone generator.
        noise *= 1.0 - np.exp(-t / (hit.attack_ms / 1000.0 / 15.0))

        buffer[start:] += (body + noise) * hit.gain

    buffer = highpass(buffer, HIGHPASS_HZ, HIGHPASS_POLES)

    fade = int(round(FADE_OUT_MS / 1000.0 * SAMPLE_RATE))
    buffer[-fade:] *= 0.5 + 0.5 * np.cos(np.pi * np.arange(fade) / fade)

    peak = np.max(np.abs(buffer))
    return buffer / peak * (10.0 ** (spec.peak_dbfs / 20.0))


def write_wav(path: Path, buffer: np.ndarray) -> None:
    samples = np.clip(buffer, -1.0, 1.0)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(SAMPLE_RATE)
        out.writeframes(np.round(samples * 32767.0).astype("<i2").tobytes())


def to_caf(wav: Path, caf: Path) -> bool:
    """Repackage as CAF, which is what iOS prefers for short one-shots."""
    if shutil.which("afconvert") is None:
        return False
    subprocess.run(
        ["afconvert", "-f", "caff", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(wav), str(caf)],
        check=True,
        capture_output=True,
    )
    return True


@dataclass
class Report:
    spec: SoundSpec
    path: Path
    ms: float
    peak_dbfs: float
    rms_dbfs: float
    dc: float
    speaker_dbfs: float
    clipped: int
    bytes: int
    problems: list[str] = field(default_factory=list)


def verify(spec: SoundSpec, buffer: np.ndarray, path: Path) -> Report:
    """Everything that can be wrong with a sample without listening to it."""
    quantised = np.round(np.clip(buffer, -1.0, 1.0) * 32767.0).astype(np.int32)
    peak = int(np.max(np.abs(quantised)))
    rms = float(np.sqrt(np.mean((quantised / 32767.0) ** 2)))
    dc = float(np.mean(quantised / 32767.0))
    clipped = int(np.count_nonzero(np.abs(quantised) >= 32767))
    ms = len(buffer) / SAMPLE_RATE * 1000.0

    through_speaker = float(np.max(np.abs(highpass(buffer, SPEAKER_HZ, SPEAKER_POLES))))

    report = Report(
        spec=spec,
        path=path,
        ms=ms,
        peak_dbfs=20 * math.log10(peak / 32767.0) if peak else -math.inf,
        rms_dbfs=20 * math.log10(rms) if rms > 0 else -math.inf,
        dc=dc,
        speaker_dbfs=20 * math.log10(through_speaker) if through_speaker > 0 else -math.inf,
        clipped=clipped,
        bytes=path.stat().st_size,
    )

    if clipped:
        report.problems.append(f"{clipped} clipped samples")
    if abs(report.peak_dbfs - spec.peak_dbfs) > 0.05:
        report.problems.append(f"peak {report.peak_dbfs:+.2f} dBFS, wanted {spec.peak_dbfs:+.2f}")
    # An offset is inaudible in itself and thumps every time playback starts or
    # stops. The bound is a thousandth of a bit: anything above that means the
    # high-pass stopped doing its job, not that a knock was asymmetric.
    if abs(dc) > 1e-5:
        report.problems.append(f"DC offset {dc:+.7f}")
    # Exactly zero, not nearly: the first and last samples are the two the
    # hardware can turn into a click.
    if quantised[0] != 0 or quantised[-1] != 0:
        report.problems.append(f"ends on {quantised[0]} … {quantised[-1]}, not silence")
    if ms > 500:
        report.problems.append(f"{ms:.0f} ms is long enough to overlap the next move")
    return report


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    reports: list[Report] = []
    # The intermediate WAVs are written outside the app's resource tree on
    # purpose: everything under App/ is bundled, so a scratch file left behind
    # by an interrupted run would ship.
    with tempfile.TemporaryDirectory() as scratch:
        for spec in SOUNDS:
            buffer = render(spec)
            wav = Path(scratch) / f"{spec.name}.wav"
            write_wav(wav, buffer)
            caf = OUTPUT_DIR / f"{spec.name}.caf"
            if not to_caf(wav, caf):
                print("afconvert not found — writing WAV instead of CAF", file=sys.stderr)
                caf = Path(shutil.move(str(wav), OUTPUT_DIR / f"{spec.name}.wav"))
            reports.append(verify(spec, buffer, caf))

    header = (
        f"{'file':<14} {'event':<28} {'ms':>7} {'peak':>8} {'rms':>8} "
        f"{'dc':>10} {'speaker':>9} {'bytes':>8}"
    )
    print(header)
    print("-" * len(header))
    for report in reports:
        print(
            f"{report.path.name:<14} {report.spec.event:<28} {report.ms:>7.1f} "
            f"{report.peak_dbfs:>7.2f}dB {report.rms_dbfs:>7.2f}dB {report.dc:>+10.2e} "
            f"{report.speaker_dbfs:>8.1f}dB {report.bytes:>8}"
        )
    print("-" * len(header))
    total = sum(r.bytes for r in reports)
    print(f"{len(reports)} files, {total / 1024:.1f} KB total")

    print()
    for report in reports:
        print(f"{report.path.name}")
        print(textwrap.fill(report.spec.note, width=78, initial_indent="  ", subsequent_indent="  "))
    print()
    print("Sanctioned events with no sound:")
    for event, reason in SILENT_EVENTS.items():
        print(textwrap.fill(f"{event} — {reason}", width=78, initial_indent="  ", subsequent_indent="    "))

    loudest = max(r.speaker_dbfs for r in reports)
    quietest = min(r.speaker_dbfs for r in reports)
    print(f"speaker spread {loudest - quietest:.1f} dB, ceiling {MAX_SPREAD_DB:.0f} dB")
    if loudest - quietest > MAX_SPREAD_DB:
        for report in reports:
            if loudest - report.speaker_dbfs > MAX_SPREAD_DB:
                report.problems.append(
                    f"{loudest - report.speaker_dbfs:.1f} dB below the loudest sound through a speaker"
                )

    failures = [(r.path.name, p) for r in reports for p in r.problems]
    if failures:
        print()
        for name, problem in failures:
            print(f"FAIL {name}: {problem}", file=sys.stderr)
        return 1

    known = {r.path.name for r in reports}
    strays = sorted(p.name for p in OUTPUT_DIR.iterdir() if p.name not in known)
    if strays:
        print()
        print(f"Not produced by this script and still in place: {', '.join(strays)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
