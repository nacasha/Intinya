# Intinya

**On-device meeting transcription for macOS.** Captures system audio and your
microphone as two separate tracks, transcribes them live, and is built for
**Bahasa Indonesia with mid-sentence English**.

*Intinya* is Indonesian for “the gist of it”.

## What it does

- **Two tracks, never mixed.** Your microphone and the meeting’s audio are
  captured and transcribed separately, so you get speaker attribution without a
  diarization model.
- **Live, then better.** A fast pass transcribes as you speak; a slower, more
  accurate model replaces those lines afterwards, in place.
- **Built for code-switching.** Pinned to Indonesian, with a glossary that keeps
  English product and technical terms intact instead of phonetically mangled.
- **Screen capture alongside.** Keyframes when the screen changes, or continuous
  video — either way a frame is one click from the line said over it.
- **Notes and annotations.** Free-form notes per recording, plus a note against
  any individual line.
- **Optional AI pass.** Repair, summarise, and extract terms, through a CLI you
  configure.

**Transcription is entirely local** — WhisperKit on Apple silicon, no account, no
upload, and it works offline. The AI pass is the one exception, and it is opt-in:
it hands the transcript to whichever command-line tool you point it at, and that
tool decides where the text goes.

## Install

Download the latest `Intinya-x.y.z.zip` from [Releases](../../releases/latest),
unzip it, and drag **Intinya** to Applications. Builds are signed with a
Developer ID certificate and notarised by Apple, so Gatekeeper opens them without
the right-click dance.

Requires **macOS 14 (Sonoma) or later**. Apple silicon strongly recommended —
transcription runs on the Neural Engine and GPU.

### Permissions

| Permission | Needed for | When |
|---|---|---|
| Microphone | Your side of the conversation | Prompted on first record |
| Screen Recording | System audio (ScreenCaptureKit) | System Settings › Privacy & Security › Screen Recording |

Recordings are written to `~/Library/Application Support/Meeting/Sessions/`.
That folder keeps its original name so recordings made before the app was renamed
are still found; it is storage, not branding.

## Build from source

```bash
git clone <this repo> && cd intinya
./Scripts/build-debug.sh       # builds and signs build/Intinya.app
./Scripts/build-debug.sh --run # ...and relaunches it
```

Uses Xcode 26.3 via `DEVELOPER_DIR` when that version is installed, so
`xcode-select` does not need changing.

`build-debug.sh` signs with your **Developer ID** identity if it finds one. That
matters more than it sounds: both permission grants are recorded against the code
signature, so an ad hoc build is a different app to macOS on every rebuild and
re-prompts each time. With no identity on the machine the script falls back to ad
hoc and says so.

### Releasing

Releases are built by the **Release** workflow, run by hand from the Actions tab.
It runs the same script with `UNIVERSAL=1`, signs with the Developer ID
certificate held in the `release` environment, notarises with Apple, staples the
ticket, and attaches a zip to a GitHub release. It needs five secrets:
`CERTIFICATE_P12` and `CERTIFICATE_PASSWORD` (a base64 Developer ID Application
`.p12`), and `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` (a base64 App
Store Connect `.p8` and its identifiers).

---

The rest of this file is how the app works and why it is built the way it is.

## How it works

```
mic   ──► AVAudioEngine    ──┐
                             ├─► 16kHz mono ──┬─► WAV on disk  (tier 2 reads this)
system ─► ScreenCaptureKit ──┘                └─► LiveChunker ─► WhisperKit (tier 1)
```

**Two tracks, never mixed.** Mic and system audio are captured, buffered,
chunked, and transcribed independently. That gives speaker attribution
("You" vs "Them") without a diarization model.

**Audio is written to disk as it is captured**, under
`~/Library/Application Support/Meeting/Sessions/<timestamp>/`. The enhanced pass
is therefore a second *read* of the same recording, not a second recording — it
can run while the meeting is still in progress.

## Indonesian + English code-switching

Four decisions matter more than the choice of model:

1. **`language: "id"` is pinned; auto-detect is off.** Whisper detects language
   per 30-second window, so with auto-detect a code-switched meeting flips to
   `en` mid-conversation and back. That flip is what produces garbage.
2. **`task: .transcribe` is forced.** Under `.translate`, Whisper silently
   renders Indonesian speech as English text — the app looks like it works and
   the transcript is wrong.
3. **Prompt conditioning** (`Model/Glossary.swift`) seeds the decoder with a
   natural code-switched Indonesian sentence containing your English vocabulary.
   Without it, Whisper phonetically Indonesianises embedded English
   ("developer" → "depeloper", "SQL" → "eskuel"). Edit the term list to match
   your team.
4. **VAD gating** (`Transcription/LiveChunker.swift`) cuts on silence rather
   than fixed intervals, and refuses to feed the decoder silent windows.
   Whisper's silence hallucination is worse in Indonesian than English.

### Models

Pick and download models from the **Models** sheet (the chip in the bottom-left
of the window). Twelve multilingual variants are offered, downloaded on demand,
and deletable. Every `.en` variant and the entire `distil-whisper` family are
excluded — Distil-Whisper is an English-only distillation and produces garbage
on Indonesian.

Naming in the model repo is genuinely confusing, so to be explicit:

* `large-v3-v20240930` **is** OpenAI's large-v3-turbo — a pruned decoder at
  roughly half the size of large-v3, still fully multilingual.
* A trailing `_turbo` is WhisperKit's own ANE-optimised encoder packaging. It is
  *not* a smaller model (`large-v3_turbo` is slightly larger than `large-v3`);
  it buys speed, not disk.
* A trailing `_NNNMB` is a quantised build — much smaller and faster, with some
  accuracy given up.

| Tier | Default | Why |
|---|---|---|
| Live | `openai_whisper-small` | Floor for Indonesian; `tiny`/`base` are not viable |
| Enhanced | `openai_whisper-large-v3-v20240930_626MB` | Best accuracy-per-MB |

Models download from HuggingFace on demand into `~/Documents/huggingface/`.

### Why Whisper, and why not something faster

Checked and ruled out:

| Candidate | Verdict |
|---|---|
| NVIDIA Parakeet TDT-0.6B-v3 / Canary-1B-v2 | Fastest open ASR available, but **25 European languages — no Indonesian** |
| Moonshine | Built for real-time edge ASR, but English-only |
| MMS-1B-all (wav2vec2 CTC, much faster) | Supports Indonesian, but 29.30 WER vs whisper-small 30.87 — no gain, and no punctuation or casing |

Whisper is the only viable family for Indonesian.

**Speed is not the constraint.** Large v3 Turbo 626MB measures 6.3x realtime on
Apple Silicon; live needs >1x. Live transcription here is accuracy-bound, not
speed-bound, which is why the live default is the turbo model rather than Small.

### Indonesian fine-tunes

| Model | Indonesian WER | Note |
|---|---|---|
| whisper-small (stock) | 30.87 | Includes spontaneous/informal speech |
| Fine-tuned Whisper (study) | 14.85 | Roughly halves the error |
| `cahya/whisper-small-id` | 6.06 | Indonesian-only training |
| `Dafisns/whisper-turbo-multilingual-fleurs` | 6.97 (EN 9.09) | Trained on id + en; LoRA adapter |

A monolingual Indonesian fine-tune is **not** an automatic win for this app.
The literature reports that fine-tuning "consistently degrades both monolingual
and code-switching performance" and that monolingual adaptation overwrites
existing capability — so an Indonesian-only model would likely make embedded
English terms worse. A model trained on **both** languages is the safer bet.

**Read every WER above with suspicion.** The Indonesian ASR study found
spontaneous *informal* speech scores 29.64 WER even for fine-tuned models,
against 10.38 for read formal speech. Meetings are spontaneous informal; those
6-7% figures are read-speech numbers and will not transfer.

To use a fine-tune, `whisperkittools` converts arbitrary Whisper checkpoints to
WhisperKit CoreML, and WhisperKit loads custom repos via `WhisperKitConfig.modelRepo`
(a LoRA adapter must be merged into the base weights first). Not yet wired into
the UI.

### Benchmarking

Speed depends on your chip, so the app measures it rather than quoting numbers.
It synthesises a known code-switched Indonesian sentence with the system
Indonesian voice, transcribes it, and reports realtime factor and word error
rate. Hit **Measure** on any downloaded model, or from the terminal:

```bash
./build/Intinya.app/Contents/MacOS/Intinya --list-models
./build/Intinya.app/Contents/MacOS/Intinya --benchmark openai_whisper-small
./build/Intinya.app/Contents/MacOS/Intinya --benchmark small large-v3-v20240930_626MB
```

Measured on an M-series Mac:

| Model | Load | Speed | Accuracy |
|---|---|---|---|
| Small | 24.6s | 7.1× realtime | 86% |
| Large v3 Turbo (626MB) | 60.2s | 6.3× realtime | 86% |

**Read the accuracy number carefully.** The sample is read by an Indonesian TTS
voice, which pronounces embedded English terms with Indonesian phonetics far
more heavily than a bilingual speaker does — both models above rendered
"backend" as "buggent"/"batchkent". That compresses the accuracy spread between
models and understates real code-switching performance. **Speed is the number to
trust**; judge accuracy on a real recording.

## Tier 2 — the enhanced pass

After a recording stops, **Enhance** re-transcribes the session WAVs with a more
accurate model and replaces the live text window by window, so the transcript
visibly sharpens instead of sitting still.

Replacement is by **time range**, not segment-to-segment matching: the live pass
and the enhanced pass chunk audio differently, so their segment boundaries do not
correspond and pairing them up would drop or duplicate text. Each completed
window removes the live segments whose midpoint falls inside it.

Live and enhanced use **separate model choices**, both set in the Models sheet —
live needs to beat realtime, enhanced does not.

Run it headlessly over any past session:

```bash
./build/Intinya.app/Contents/MacOS/Intinya --enhance "~/Library/Application Support/Meeting/Sessions/<session>"
./build/Intinya.app/Contents/MacOS/Intinya --enhance <dir> openai_whisper-large-v3
```

Measured: 184s of Indonesian speech re-transcribed in 27.1s (**6.8× realtime**)
with Large v3 Turbo 626MB — fast enough to run while the meeting is still going.

## Library and playback

The sidebar lists every past recording, newest first, with duration, line count,
and whether it has been enhanced. Selecting one opens playback:

- **Transport** — play/pause (space bar), scrubber, elapsed/total time
- **Synchronised highlight** — the line currently playing is outlined and scrolls
  itself into view
- **Click any line to play from there** — with a 0.25s lead-in so the first word
  is not clipped
- **Per-track mute** — isolate the mic or system side; tracks the recording does
  not contain are shown disabled
- **Copy** the transcript as timestamped text, or **Reveal** the folder

Playback position comes from the audio node's render clock rather than a wall
timer, so the highlight stays locked to the audio instead of drifting.

## Notes

Each session has a free-form markdown note, saved as `notes.md` beside the
audio. Write/Preview toggle, autosaved on a debounce and flushed on pane
switches. Plain markdown on disk rather than a field inside the transcript JSON:
notes are the part a person writes by hand and should stay readable without this
app.

## Audio sources

Both tracks are choosable, before you hit Record:

| Track | Choices |
|---|---|
| **Microphone** | System default, or any input device with usable channels |
| **System audio** | All system audio, or a single application |

List what is available, and check both permissions, with:

```bash
./build/Intinya.app/Contents/MacOS/Intinya --audio-sources
```

Input devices come from CoreAudio rather than `AVCaptureDevice`, because the
`AudioDeviceID` is what has to be set on the engine's audio unit anyway, and
because the input channel count is readable *before* selecting a device. That
last part matters: an aggregate or virtual device can advertise a sample rate
while exposing no input channels at all, and enumerating through CoreAudio lets
those be filtered out of the list instead of discovered by failing at record time.

The device is set with `kAudioOutputUnitProperty_CurrentDevice` on
`engine.inputNode.audioUnit`, which is the only way to point `AVAudioEngine` at
something other than the system default, and only works while the engine is
stopped. Nothing downstream changes: `AudioResampler` rebuilds its converter
whenever the input format changes, so a 44.1 kHz interface and a 48 kHz one both
arrive as 16 kHz mono.

**App audio captures helper processes too.** Chromium and Electron apps play
audio from a helper, not from the process that owns the window — Chrome's audio
is `com.google.Chrome.helper.renderer`, not `com.google.Chrome`. Selecting an app
therefore includes every running process whose bundle ID is the chosen one or is
namespaced under it. Matching only the parent is why per-app capture records
silence on Chrome, Slack, Discord, Teams and VS Code, which is most of the apps a
meeting actually runs in.

Scoping to an app also *excludes* everything else, notification sounds included.
That is the point, but it means all-system is the safer default and per-app is
the sharp tool.

If a chosen mic is unplugged or a chosen app has quit, recording does not fail:
it falls back to the default input or to all-system audio and says so, rather
than silently capturing nothing.

## Screen capture

Chosen per recording, before you hit Record:

| Mode | What it does |
|---|---|
| **No screen** | Audio only |
| **Keyframes** | A still each time the screen meaningfully changes |
| **Video** | Continuous H.264 via `SCRecordingOutput` (macOS 15+) |

Target is either the whole display or a single window, listed from
`SCShareableContent`. Check discovery and permissions with:

```bash
./build/Intinya.app/Contents/MacOS/Intinya --screens
```

**Keyframes are the default, and for slide-driven meetings they are the better
choice.** Meeting screens are static — a slide sits for two minutes, so video
spends bits encoding nothing. The question you actually ask later is "what was
on screen when this was said", which is a timestamp lookup, not a scrub: click a
transcript line and the frame appears. Roughly 20-60 MB/hour against a few
hundred for video, and near-zero CPU, which matters because live transcription is
already using the GPU. Video is the right pick when motion carries meaning —
demos, scrolling, cursor work.

Change detection compares a 32x32 greyscale signature rather than full frames:
~1000 comparisons instead of millions, and it ignores antialiasing and cursor
blink that would otherwise make every frame look different. A frame is kept when
>6% of cells change, at most once per second so an animation cannot produce
hundreds of files.

Screen capture runs its **own** `SCStream`, separate from system audio. Sharing
one stream would let the screen target dictate the audio filter — pick a single
window and you would silently stop capturing system audio from everything else.

In playback, the Screen tab shows the frame matching the playhead plus a
filmstrip; clicking any thumbnail plays from that moment.

### Transcript storage

Each session directory holds `mic.wav`, `system.wav`, and `transcript.json`:

```
~/Library/Application Support/Meeting/Sessions/<timestamp>/
├── mic.wav
├── system.wav
├── transcript.json     segments, timestamps, tiers, models used, keyframe index
├── notes.md            free-form markdown (absent if empty)
├── frames/             keyframe stills, named by centisecond offset
└── screen.mov          only when recorded in video mode
```

Transcripts are written when recording stops, again as trailing live chunks
land, and progressively during the enhanced pass — so quitting mid-enhancement
does not lose what was already improved. Sessions recorded before transcripts
were persisted still open and play; they just have no text.

`--enhance` also writes `transcript.json`, so re-running it over an old session
gives that session a transcript in the app.

## Threading

Nothing per-audio-packet runs on the main thread. `CaptureIngest` owns a serial
queue that does WAV writing and chunking, and calls back on main with results
already throttled to ~20 Hz.

This matters more than it sounds. The original version did both inline in a
`@MainActor` method, and the chunker re-ran voice-activity detection over the
*entire* pending buffer on every packet — O(buffer) work, with the buffer growing
to 14 seconds, ~12x per second per track. Main-thread cost climbed as the buffer
filled until SwiftUI stalled and the window went blank. Voice activity is now
computed incrementally, one frame at a time, and cached.

Check it with:

```bash
./build/Intinya.app/Contents/MacOS/Intinya --chunkbench 600
```

Per-packet cost should stay flat as the duration grows:

| Audio | Total CPU | Worst packet |
|---|---|---|
| 60s | 1.0 ms | 0.117 ms |
| 600s | 4.5 ms | 0.052 ms |

A packet arrives every ~85 ms, so worst case uses well under 1% of budget.

The waveform also deliberately avoids `.drawingGroup()` and implicit animation
over its level array — offscreen Metal rasterisation every frame, plus array
interpolation, produced blank and mis-sized frames under transcription load.

## Troubleshooting: silent recordings

**macOS hands an app digital silence rather than an error when a microphone grant
is not in effect.** Recording then "succeeds" and produces a silent file. An ad
hoc build changes its code signature on every rebuild and so invalidates an
existing grant — which is the reason `build-debug.sh` signs with a Developer ID.

The app now detects this: if a track produces exact zeros for 8 seconds while
nominally recording, a warning banner appears. To check the microphone directly:

```bash
./build/Intinya.app/Contents/MacOS/Intinya --mictest 5
```

If it reports SILENT, remove Intinya from System Settings › Privacy & Security ›
Microphone, relaunch, and approve the prompt again.

Session WAV headers are also patched every ~5 seconds during capture, so a
recording interrupted by a crash or force quit stays readable. `WAVReader`
additionally recovers files whose header was never finalised by taking the length
from the file itself.

## Tier 3 — the AI pass

Uses your **existing Claude Code subscription**. There is no API key and nothing
for this app to authenticate: it spawns your own `claude` binary, which reads its
credentials from `~/.claude` exactly as it does in a terminal. The subscription
is consumed by Claude Code itself.

**Polish with AI** on a session does three things in one pass:

1. **Repairs transcription errors** — the ones no ASR model can fix, because the
   information is not in the audio. Measured on a real recording:
   `Najila Syahp` → `Najelaa Shihab`, `ganti mulia` → `ganti melulu`,
   `Sejaanra` → `Sejahtera`, `Oh aset lah` → `Oh asli lah`.
2. **Writes a summary into `notes.md`** — appended, never overwriting, because
   notes are hand-written and must not be replaced by a machine.
3. **Learns vocabulary** — recurring proper nouns and product names are saved and
   fed back into `Glossary`, which is Whisper's prompt conditioning. **Each
   meeting makes the next one transcribe more accurately.**

Roughly 20s for a short recording.

```bash
./build/Intinya.app/Contents/MacOS/Intinya --polish "<sessionDir>" --dry-run
./build/Intinya.app/Contents/MacOS/Intinya --polish "<sessionDir>"
```

### Why a login shell is captured first

A GUI-launched app's PATH is `/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin:.` — it
excludes `~/.local/bin` where `claude` usually lives, and shell **aliases** (which
`claude` often is) are invisible to any spawned process. Running `claude` naively
fails with "command not found", and that is the usual reason this approach
appears not to work.

`ShellEnvironment` therefore starts the user's login shell once, has it write its
whole environment to a temp file with `env -0`, and reuses that for every child
process. A file rather than stdout, because a `.zshrc` banner or motd would
otherwise be mixed into the output; `-0` because env values can contain newlines.

### Provider design

`AIProvider` is one-shot text-in / text-out. The agent CLIs also offer a
persistent streaming session with tool permissions, but that machinery exists for
hosting interactive coding agents — a transcript repair is a single
transformation. Instruction goes as an argument, transcript on **stdin** (an hour
of speech would overflow the argument size limit), and the tool runs in a scratch
directory so it cannot touch the recording. The app owns its files.

`CustomCommandProvider` takes an argv template with `{prompt}`, so another CLI —
or a changed flag — never requires a code change here.

## Status

Tiers 1 and 2 are complete and verified: dual-track capture, VAD-gated live
transcription pinned to Indonesian, the enhanced re-transcription pass, session
recording with crash-safe WAVs, the model picker with on-demand download and
on-device benchmarking, selectable microphone and system-audio source, and
silent-input detection.

Since then: per-line annotations, a terms view showing which glossary entries a
recording actually used, and a document-style playback layout.

Not yet built:
- Glossary editing in the UI (terms are learned automatically, but cannot yet be
  reviewed or removed by hand).
- Ask-the-meeting Q&A over one or many transcripts.
- Codex / Cursor / Ollama providers (the protocol and custom-command escape
  hatch are in place; only Claude Code is wired up).

## Layout

```
Sources/Intinya/
├── Audio/           capture, resampling, WAV writing
├── Transcription/   WhisperKit engine, VAD chunker, model list
├── Model/           recorder coordinator, segments, glossary
└── UI/              SwiftUI views, theme
```
