# Construe

Construe is a macOS menu-bar app for making sense of text you run into while doing something else: a line of dialogue in
a show, a sentence in a book, a phrase in a document. Press a shortcut, type or paste the text (or a screenshot of it),
and Claude's explanation streams into a small popup over whatever you were doing. When you want to dig deeper, one click
continues the conversation on claude.ai.

What Claude does with the text is up to you: the system prompt is yours to write. The default translates
foreign-language text and breaks down anything non-obvious.

## Features

- **Global shortcut** (⌃⌥Space by default) opens a popup over any app, including fullscreen ones, without switching
  Spaces or stealing focus. Esc or clicking elsewhere closes it and returns you to where you were.
- **Paste a screenshot** (for example subtitles grabbed with ⌘⇧⌃4) and its text is recognized on your Mac, then placed
  in the input so you can trim it to the exact phrase. Optionally the image itself is sent along, so Claude can correct
  recognition mistakes.
- **Grab a screen region** straight from the popup, without a screenshot: drag a rectangle over the text and it is read
  the same way. **Re-grab** reads the same rectangle again, which is handy for subtitles that always appear in the same
  place, and also works from any app.
- **Listen and catch audio**: start listening when you start watching, and Construe keeps the last few seconds of sound
  your Mac plays in memory. When you miss a phrase, open the popup: the buffer is transcribed on your Mac and the
  text lands in the input, ready to trim and send. Silence doesn't use up the buffer, so pausing a video keeps the
  phrase before the pause.
- **Streaming, formatted replies** with headings, lists and clickable links. The last reply stays in the popup when you
  close it, so following a link doesn't lose it.
- **Continue in Claude** opens a new claude.ai chat, optionally inside one of your Projects, prefilled with the phrase
  and the reply, ready for your follow-up question.

## Requirements

- macOS 26.7 or later
- An Anthropic API key from the [Claude Console](https://platform.claude.com). API usage is billed to your Console
  account (prepaid credits), separately from any claude.ai subscription.
- A claude.ai account, only for the Continue in Claude handoff

## Getting started

Download the `.dmg` of the latest release from the [Releases page](https://github.com/CthulhuDen/construe/releases)
and copy Construe to your Applications folder, or build it from source (see [Development](#development)).

1. Launch Construe. A speech-bubble icon appears in the menu bar; the app has no Dock icon.
2. Open **Settings…** from the menu-bar icon.
3. On the **Claude** tab, paste your API key.
4. Optionally, write your own system prompt and set a claude.ai Project for handoffs on the **Handoff** tab.

## Using Construe

| Action | How |
|---|---|
| Open or close the popup | ⌃⌥Space (changeable in Settings > General) |
| Send | Return |
| New line in the input | ⇧Return |
| Paste a screenshot | ⌘V with an image on the clipboard |
| Grab a screen region | ⌃⌥X in the popup, then drag; Esc cancels |
| Re-grab the last region | ⌃⌥C, in the popup or from any app |
| Start or stop listening | ⌃⌥L, the menu-bar menu, or Listen in the popup |
| Continue in Claude | ⌘↩, or the button under a finished reply |
| Open Settings | ⌘, in the popup, the menu-bar menu, or launching Construe again |
| Close | Esc, or click anywhere else |

The grab and re-grab shortcuts are changeable in Settings > General; clear the global re-grab there to give ⌃⌥C back to
other apps. Grabbed text is added to the input like a pasted screenshot; the last region is forgotten when Construe quits.

While listening, the menu-bar icon changes to an ear, and opening the popup transcribes the last few seconds of sound
into the input. The text is never sent automatically. The caught audio shows as a waveform under the input; click it to
replay what was transcribed. The buffer length (15 seconds by default), the recognition language (by default the first
language in System Settings > General > Language & Region) and how long a silence stops listening (30 minutes by
default) are in Settings > Listening. Listening follows the output device: switching to headphones or another output
while listening keeps what's already buffered and carries on capturing from the new device.

Each time you open the popup the input is empty, but the previous reply is still there. A reply that is still streaming
keeps going in the background when you close the popup.

## Privacy

- Your API key stays in your Keychain and is only sent to the Anthropic API.
- Screenshots are read on your Mac with Apple's Vision framework. The text you send, and the screenshot if image
  attachment is on, go to the Anthropic API under your Console account's data policies.
- Continue in Claude puts the phrase and reply into a claude.ai link that opens in your browser.
- Grabbing a screen region needs the Screen Recording permission, which macOS asks for on first use. Construe captures
  only the region you selected, only when you ask, and handles it like a pasted screenshot.
- Listening captures all sound your Mac plays (except Construe's own) but keeps only the last few seconds of sound, in
  memory. It is never written to disk and is discarded when listening stops.
- Audio is transcribed on your Mac, only when you open the popup while listening, and the transcript goes into the
  input like typed text.
- Listening captures audio only, through a Core Audio process tap; it doesn't record the screen. It needs the System
  Audio Recording permission, which macOS asks for the first time you start listening (Privacy & Security > Screen &
  System Audio Recording > System Audio Recording Only). If Construe already has Screen & System Audio Recording (for
  grabbing a region), that covers listening too. The purple recording indicator shows in the menu bar while
  listening. macOS has no way for an app to check this permission, so if it's denied, the popup reports that there
  was no sound.
- The speech model is downloaded from Apple once per language.
- Construe has no server and no analytics.
- Construe logs to macOS unified logging (Console.app), which stays on your Mac. Your text, recognized text and replies
  are logged as private, so they show as `<private>`; the API key is never logged. **Settings > General > Copy
  Diagnostics** copies the last hour of the log for a bug report.

## Limitations

- Continue in Claude can't carry screenshots, only text.
- claude.ai cuts off very long prefills, so the handoff text is capped at 12,000 characters by trimming the end of the
  reply.
- Opening a Project via the link relies on claude.ai's undocumented `project` parameter, which may stop working. Without
  a Project ID the documented `claude.ai/new?q=` link is used.
- claude.ai shows a "Use caution before running this prompt" banner for prefilled prompts; that is expected.
- DRM-protected playback (Apple Music, Apple TV+, Netflix in Safari) may be captured as silence, so it can't be caught.
- The first words of caught audio may be cut mid-word, because the buffer starts wherever the oldest kept sound is.
- Listening languages are limited to those Apple's on-device `SpeechTranscriber` supports.

## Development

### Setup

1. Install Xcode 27.1 or later.
2. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and set your `DEVELOPMENT_TEAM` and
   `PRODUCT_BUNDLE_IDENTIFIER`.
3. Open `Construe.xcodeproj` and run the **Construe** scheme.

The keychain access group is a restricted entitlement, so builds need a signing team with a provisioning profile;
Xcode's automatic signing creates it. Per-developer values never go into `project.pbxproj`; see [AGENTS.md](AGENTS.md).

### Project layout

| Folder | Contents |
|---|---|
| `Construe/Panel` | The popup: non-activating `NSPanel`, its controller, the SwiftUI view and the AppKit input field |
| `Construe/Session` | One popup session: input, screenshot, streamed reply |
| `Construe/API` | Messages API client (raw HTTP with SSE streaming; Swift has no official SDK) |
| `Construe/OCR` | Vision text recognition |
| `Construe/Capture` | Screen region selection overlay and ScreenCaptureKit capture |
| `Construe/Listening` | Listening sessions: system audio capture (Core Audio process tap) and the in-memory ring buffer |
| `Construe/Speech` | On-device speech recognition of caught audio |
| `Construe/Handoff` | claude.ai link building, the only place that knows claude.ai URLs |
| `Construe/Settings` | Settings model (UserDefaults), Keychain store, Settings window |
| `Construe/Logging` | `os.Logger` categories and the Copy Diagnostics log reader |
| `ConstrueTests` | Swift Testing suites |

### Tests

There are two test plans:

- **Unit** (default, ⌘U): everything except the `integration` tag. No network access; Anthropic API responses are served
  by a stub `URLProtocol`, and test images are drawn in code.
- **Integration**: only the `integration`-tagged tests, which call the real API (a few cents per run). Add
  `ANTHROPIC_API_KEY = sk-ant-…` to `Config/Local.xcconfig`, ideally a key from a Console workspace with a low spend
  limit. Without a key these tests fail with a pointer to this setup. The plan also includes the on-device
  transcription test, which may download the en-US speech model once.

From the terminal:

```sh
xcodebuild test -scheme Construe -testPlan Unit -destination 'platform=macOS'
xcodebuild test -scheme Construe -testPlan Integration -destination 'platform=macOS'
```
