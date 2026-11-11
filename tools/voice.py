"""Makes the voice clips the radios play, so they can be made again.

    .venv/Scripts/python tools/voice.py [--voice piper:en_GB-cori-medium] [--all]

Neither radio has text-to-speech, so every phrase in src/core/phrases.lua
(and every mode name) is a WAV file in src/audio/en/, as both radios play
them: 16 kHz, 16-bit mono, trimmed, every clip at one peak level. Only clips
whose words or voice changed are made again, unless --all.
src/audio/en/index.txt records each clip's voice and words; tools/test.py
checks it against the phrases, so a phrase without its clip fails the checks.

The voice is Piper's "cori" (Eric's choice from sampling 13, 2026-11-10): an
open-source neural voice that runs offline, trained on recordings licensed
CC BY 4.0, which src/audio/en/CREDITS.txt credits. Its model is downloaded
once into out/voices, from a fixed revision, and checked. "sapi:<name>"
names a Windows voice instead.
"""
import argparse
import hashlib
import io
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import urllib.request
import wave

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "src" / "audio" / "en"
INDEX = OUT / "index.txt"
MODELS = ROOT / "out" / "voices"
RATE = 16000
DEFAULT_VOICE = "piper:en_GB-cori-medium"
# Silence kept around the words, enough not to clip a soft start, and what
# counts as silence.
MARGIN_S = 0.04
QUIET = 0.012
# Every clip's peak, -1 dBFS, so no callout is quieter than another.
PEAK = 0.89

# Piper's voices, from a fixed revision of rhasspy/piper-voices, checked.
PIPER_REVISION = "cf910fb59f1d79ab3b625a63993a108751c6c25d"
PIPER_VOICES = {
    "en_GB-cori-medium": {
        "path": "en/en_GB/cori/medium/en_GB-cori-medium",
        "onnx": "2e0a55e140de672aa19b182602b407607bd2e6c35fc6020c0b1516053c02e995",
        "json": "f89b01c5e483c75ce9085ff89c79446c1a95a1cb4a362f629dac3b5a4b5dde75",
    },
}
# What Piper says badly, respelled. It reads a lone capital A as the
# article ("uh"), where the phrases mean the letter. "Fly by wire" as three
# words sounded robotic, and run together it guesses "bih" for "by";
# "fly-bye-wire" is one word with each syllable full (Eric's pick of eight).
PIPER_RESPELL = [
    (re.compile(r"\bA\b"), "eh"),
    (re.compile(r"\bFly by wire\b"), "Fly-bye-wire"),
]


def phrases():
    """Clip name to words, from the core itself."""
    import lupa.lua54 as lua
    rt = lua.LuaRuntime()
    read = lambda path: (ROOT / path).read_text(encoding="utf-8")  # noqa: E731
    use = rt.eval("""function(read)
        local cache = {}
        local function use(name)
          if cache[name] == nil then
            cache[name] = assert(load(read("src/core/" .. name .. ".lua"), "@" .. name))(use)
          end
          return cache[name]
        end
        return use
      end""")(read)
    table = use("phrases").all()
    return {k: v for k, v in table.items()}


def read_index():
    """Clip name to (voice, words), as last made."""
    out = {}
    if INDEX.exists():
        for line in INDEX.read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                name, voice, words = line.split("|", 2)
                out[name] = (voice, words)
    return out


def write_index(index):
    lines = ["# Lofty PFD voice clips, made by tools/voice.py: name|voice|words"]
    lines += ["%s|%s|%s" % (n, v, w) for n, (v, w) in sorted(index.items())]
    INDEX.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def fetch(url, path, sha256):
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != sha256:
        print("downloading " + url)
        path.parent.mkdir(parents=True, exist_ok=True)
        data = urllib.request.urlopen(url).read()
        if hashlib.sha256(data).hexdigest() != sha256:
            sys.exit("%s does not match its checksum" % url)
        path.write_bytes(data)
    return path


def piper(texts, name):
    """Each text as (samples, rate), in Piper voice `name`."""
    from piper import PiperVoice
    spec = PIPER_VOICES[name]
    base = "https://huggingface.co/rhasspy/piper-voices/resolve/%s/%s" % (PIPER_REVISION, spec["path"])
    model = fetch(base + ".onnx", MODELS / (name + ".onnx"), spec["onnx"])
    fetch(base + ".onnx.json", MODELS / (name + ".onnx.json"), spec["json"])
    voice = PiperVoice.load(str(model))
    out = []
    for text in texts:
        for pattern, spelled in PIPER_RESPELL:
            text = pattern.sub(spelled, text)
        buf = io.BytesIO()
        with wave.open(buf, "wb") as w:
            voice.synthesize_wav(text, w)
        out.append(read_wav(buf.getvalue()))
    return out


def sapi(texts, name):
    """Each text as (samples, rate), in a Windows voice."""
    with tempfile.TemporaryDirectory() as tmp:
        jobs = [{"words": t, "path": str(pathlib.Path(tmp) / ("%d.wav" % i))} for i, t in enumerate(texts)]
        listing = pathlib.Path(tmp) / "jobs.json"
        listing.write_text(json.dumps(jobs), encoding="utf-8")
        script = r"""
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SelectVoice('%s')
foreach ($j in (Get-Content -Raw -Encoding UTF8 '%s' | ConvertFrom-Json)) {
  $s.SetOutputToWaveFile($j.path); $s.Speak($j.words)
}
$s.SetOutputToNull()
""" % (name.replace("'", "''"), listing)
        subprocess.run(["powershell", "-NoProfile", "-Command", script], check=True)
        return [read_wav(pathlib.Path(j["path"]).read_bytes()) for j in jobs]


def read_wav(data):
    import numpy as np
    with wave.open(io.BytesIO(data), "rb") as w:
        rate, width, channels = w.getframerate(), w.getsampwidth(), w.getnchannels()
        frames = w.readframes(w.getnframes())
    assert width == 2, "16-bit PCM expected"
    x = np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768
    if channels > 1:
        x = x.reshape(-1, channels).mean(axis=1)
    return x, rate


def radio_clip(samples, rate):
    """The clip as the radios play it: 16 kHz, without the silence around
    the words, at the common peak; as WAV bytes."""
    import numpy as np
    import soxr
    x = soxr.resample(samples, rate, RATE) if rate != RATE else samples
    loud = np.nonzero(np.abs(x) > QUIET)[0]
    if len(loud):
        margin = int(MARGIN_S * RATE)
        x = x[max(0, loud[0] - margin):loud[-1] + margin]
    peak = float(np.max(np.abs(x))) if len(x) else 0.0
    if peak > 0:
        x = x / peak * PEAK
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())
    return buf.getvalue()


def voice_id(voice):
    """The voice as the index records it: for Piper, with a fingerprint of
    the respellings, so changing one makes the clips again."""
    if voice.startswith("piper:"):
        table = repr([(p.pattern, s) for p, s in PIPER_RESPELL])
        return voice + "+" + hashlib.sha256(table.encode()).hexdigest()[:8]
    return voice


def speak(texts, voice):
    engine, _, name = voice.partition(":")
    if engine == "piper":
        return piper(texts, name)
    if engine == "sapi":
        if sys.platform != "win32":
            sys.exit("Windows voices need Windows")
        return sapi(texts, name)
    sys.exit("unknown voice %s: piper:<name> or sapi:<name>" % voice)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--voice", default=None, help="piper:<name> or sapi:<Windows voice> (default: %s)" % DEFAULT_VOICE)
    ap.add_argument("--all", action="store_true", help="make every clip again")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    want = phrases()
    index = read_index()
    voice = args.voice or DEFAULT_VOICE
    vid = voice_id(voice)
    todo = [n for n, w in sorted(want.items())
            if args.all or index.get(n) != (vid, w) or not (OUT / (n + ".wav")).exists()]
    stale = [n for n in index if n not in want]
    for n in stale:
        (OUT / (n + ".wav")).unlink(missing_ok=True)
        del index[n]
    if todo:
        for n, (samples, rate) in zip(todo, speak([want[n] for n in todo], voice)):
            (OUT / (n + ".wav")).write_bytes(radio_clip(samples, rate))
            index[n] = (vid, want[n])
    write_index(index)
    print("made %d clips, removed %d, %d in all (%s)" % (len(todo), len(stale), len(index), voice))


if __name__ == "__main__":
    main()
