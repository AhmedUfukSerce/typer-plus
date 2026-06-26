# Typer+

Typer+ is a small macOS menu bar app that types out whatever text you give it, one real keystroke at a time. It never pastes. The whole point is that it types the way a person does: the speed drifts around the way a real typist's does, common letter pairs come out a little faster, it makes the occasional typo and goes back to fix it (sometimes right away, sometimes a few letters later), and it leaves a couple of small grammar slips that it quietly cleans up at the end, the way you do when you reread your own writing.

Every character goes in through the macOS HID layer as a CGEvent, so the app you're typing into sees ordinary hardware keystrokes (real `isTrusted` input). It reads your clipboard once to grab the text and then leaves it completely alone. Nothing is ever pasted.

A note before you get excited: this is a personal tool I wrote for my own machine. It synthesizes keyboard input and it listens for a stop gesture, so it has no business running on a work managed (MDM) Mac. If you want the honest version of how this works and how detectable it actually is, read [`RESEARCH.md`](RESEARCH.md). I tried not to oversell it there.

## The four modes

- **Fast** is quick everyday typing, somewhere around 85 to 100 wpm.
- **Natural** is your average human typist, about 52 to 56 wpm. This is the default and the one I use most.
- **Careful** is slow and deliberate, around 27 wpm.
- **Max Stealth** keeps a natural cadence but paces the whole thing on composition wall-clock time, with extra pauses and shorter bursts, so that if someone scrubs back through a document's version history it reads like it was actually written rather than dumped in. Reach for this one when edit history is the thing you care about.

## Building it

You need the Swift toolchain on macOS 14 or newer. I built and tested it on macOS 26 on Apple Silicon.

```bash
./scripts/build_app.sh
open "$HOME/Desktop/Typer+.app"   # the script prints the real path
```

A keyboard icon shows up in your menu bar. Running `swift build` on its own only gives you the bare binary. The menu bar item and the global hotkey only work from the assembled `.app` bundle, which is what the script builds.

### Run the de-risk test first

This whole thing rests on two assumptions: that the browser treats the injected keystrokes as real input, and that the target text field actually takes them. Before you trust the full app, prove both:

```bash
swift run InjectTest
```

Then walk through [`docs/test-instructions.md`](docs/test-instructions.md).

### The headless self test

```bash
swift run TyperPlus --selftest
```

This checks that the planner reproduces your text exactly, that every correction fully undoes the slip it introduced, and that the timing numbers (wpm, dwell, variation, rollover) land where the research says they should.

## First run and permissions

macOS will ask for permission, and the app deep links you straight to the right settings pane:

**System Settings, Privacy and Security, Accessibility**, then turn on **Typer+**.

That single grant covers both posting keystrokes and watching for the stop gesture. If the menu says it needs permission or that the kill switch is unavailable, finish the grant and relaunch.

If you want the grant to survive rebuilds instead of resetting every time, sign the app with a stable identity. The how-to is in the comments at the top of [`scripts/build_app.sh`](scripts/build_app.sh).

## Using it

1. Copy or write the text you want typed.
2. Click the menu bar icon, choose **Type pasted text**, paste your text into the box, pick a mode, and hit **Type this**. Or skip all that and press the global hotkey **Cmd+Option+T** to type whatever is already on your clipboard.
3. You get a short countdown. Use it to click into the field you want the text to land in. Typing starts when the countdown ends.

To stop, press **Esc three times fast**, or pick **Stop typing** from the menu.

There's also a URL scheme if you want to drive it from a script: `open typerplus://clipboard` types the clipboard, `open typerplus://stop` stops.

## How it stays out of trouble

- **It never pastes.** Every character is its own real, individually timed keystroke.
- **Triple Esc is a hard stop.** It runs on a separate self healing global tap that has nothing to do with the typing engine, and Typer+ never injects an Esc itself, so the stop gesture can't be confused for one of its own keystrokes.
- **It backs off when you touch the keyboard or mouse.** It pauses the moment you take over and picks back up after a short quiet stretch. It recognizes its own keystrokes separately so it doesn't trip over itself.
- **It freezes during secure input.** While a password field or Secure Input is active it stops entirely, so no keystrokes get dropped and the stop gesture is never in question.

## How it's put together

| File | What it does |
|---|---|
| `Sources/TyperPlus/KeyboardEngine.swift` | posts keystrokes at the HID level with CGEvent, and never pastes |
| `Sources/TyperPlus/Planner.swift` | turns text into a timed list of actions, including the typos, the corrections, and the cleanup pass |
| `Sources/TyperPlus/Timing.swift`, `TypingProfile.swift` | the timing model (inter key intervals, dwell, pauses) and the mode presets |
| `Sources/TyperPlus/Typos.swift`, `TextCleanup.swift` | how mistakes get made and unmade, plus the homophone layer and the end of text tidy up |
| `Sources/TyperPlus/Player.swift` | plays the plan back on the main thread, safe to pause or abort mid run |
| `Sources/TyperPlus/KillSwitch.swift` | the triple Esc stop and the bookkeeping that separates its input from yours |
| `Sources/TyperPlus/AppController.swift`, `MenuBarController.swift`, `PasteBoxPopover.swift`, `Hotkey.swift` | the control flow and the UI |
| `Sources/TyperPlus/UI/` | the SwiftUI main window, the design system, the bundled Inter fonts |
| `Sources/InjectTest/` | the de-risk harness from above |
| [`RESEARCH.md`](RESEARCH.md) | the research it's built on, and a straight account of its limits |

## License

[MIT](LICENSE). Copyright 2026 Ahmed Ufuk Serce.

I wrote this for personal use. Whatever you do with it is on you, including staying on the right side of the terms of whatever you type into.
