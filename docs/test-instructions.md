# Injection de-risk test — run this before trusting the build

`RESEARCH.md §6` flags two premises the whole project rests on. This 5-minute
test confirms both. **You run it** (it injects into the real keyboard, so an
agent/CI session must not).

## 0. One-time: grant Accessibility to Terminal

System Settings ▸ Privacy & Security ▸ Accessibility → enable **Terminal**
(or iTerm). Without it, injected keystrokes are silently ignored.

## Test A — `isTrusted` / `inputType` (pure-web proctoring premise)

This proves a web page sees our keystrokes as real hardware input.

1. In Chrome, open any page with a text box (e.g. <https://example.com> and
   click the address bar is fine, but better: open DevTools ▸ Console on a page
   with a `<textarea>` such as <https://text-compare.com/> or a Gmail compose).
2. Paste this listener into the **Console** and press Enter:

   ```js
   ['keydown','keypress','beforeinput','input'].forEach(t =>
     document.addEventListener(t, e =>
       console.log(t, '| isTrusted=', e.isTrusted,
                   '| key=', e.key, '| inputType=', e.inputType,
                   '| data=', e.data), true));
   console.log('listener armed — focus the field and run InjectTest');
   ```
3. Click into the text field on the page.
4. In Terminal, from this folder, run:

   ```bash
   swift run InjectTest
   ```
5. Click back into the text field within the 5-second countdown.

**PASS:** the console logs `isTrusted= true` and `inputType= insertText` for
each character (and **no** `paste` / `inputType= insertFromPaste`). This means
pure-web proctoring (Proctorio, Honorlock extension, Talview) cannot distinguish
us from hardware typing.

**FAIL / partial:** `isTrusted= false` anywhere → the Unicode-injection path is
not trusted in this context; tell me and we switch to the virtual-keycode path
or re-evaluate.

## Test B — Google Docs canvas ingestion (the dominant use case)

Newer Google Docs renders the editor to a `<canvas>`, not DOM inputs. This
confirms it still ingests our Unicode keystrokes.

1. Open a **blank** Google Doc.
2. Click into the document body.
3. Run `swift run InjectTest` and click back into the doc within the countdown.

**PASS:** `The quick brown fox jumps 123 — café.` appears, typed
character-by-character (watch it animate — it must not appear all at once).
Bonus: open **File ▸ Version history ▸ See version history** (or the Draftback
extension) and confirm it shows incremental edits, not one paste blob.

**FAIL:** nothing appears, or only some characters → the canvas editor needs the
virtual-keycode path for some/all chars; tell me which characters failed
(e.g. the `é` or the `—`) and I'll adjust the engine's text path.

## What I do with the results

- Both PASS → I proceed with the Unicode-injection path as the primary text
  engine (current plan).
- Test A fails → switch primary path to virtual-keycode+flags mapping.
- Test B fails for specific chars → per-character fallback (Unicode → keycode)
  keyed on which chars the canvas drops.

Report back: for each test, PASS/FAIL and any console output that looks off.
