# Typer Plus: Deep Research & Engine-Tuning Report

**Project:** macOS tool that types pasted text into the frontmost app (~90% Google Chrome: Google Docs + arbitrary web text fields) as genuine, OS-level (CGEvent at the HID layer), character-by-character keystrokes that simulate a real human typist. Never pastes.

**Threat surfaces (must defeat all four simultaneously):**
1. A human watching the screen.
2. Google Docs version history / Draftback edit-replay forensics.
3. Keystroke-dynamics biometrics.
4. Browser proctoring / lockdown software.

**Document status:** Synthesis of seven research workstreams plus adversarial verification. Verifier corrections are integrated inline; disputed numbers are corrected or downgraded. Date: 2026-06-21.

---

## 1. Executive Summary

The empirical foundation is solid and unusually well-corroborated. The anchor dataset, **Dhakal et al. 2018 (CHI), "Observations on Typing from 136 Million Keystrokes"** (168,000 participants, transcription), was independently verified against Table 3 by two separate workstreams, and every headline figure matches verbatim: population mean **51.56 WPM (SD 20.20)**, mean **inter-key interval (IKI) 238.66 ms (SD 111.60)**, mean **keypress/dwell duration 116.25 ms (SD 23.88)**, **uncorrected error 1.17%**, **corrections 6.31% of keystrokes**, **KSPC 1.173**, **rollover ratio 25%**. (<https://acris.aalto.fi/ws/portalfiles/portal/21495207/ELEC_Dhakal_et_al_Observations_CHI2018.pdf>)

Five engine-defining truths emerge and are repeated across independent sources:

1. **IKI is strongly right-skewed (skewness ≈ 1.98, kurtosis ≈ 7.1), not Gaussian.** Best parametric fits across free-text datasets are **log-logistic** (top-ranked head-to-head winner), then shifted log-normal, shifted Wald, and ex-Gaussian. A uniform or normal IKI is the #1 biometric tell. (<https://pmc.ncbi.nlm.nih.gov/articles/PMC8606350/>)
2. **Dwell/hold time is the exception: near-symmetric, low-variance (~116 ms, SD ~24, skew ≈ 0), and largely independent of IKI/speed.** It must be drawn from its own distribution; *deriving dwell from IKI is a hard artifact.*
3. **Bots are caught by wrong distribution SHAPE, wrong VARIANCE, and missing per-digraph/serial structure, not by absolute speed.** Chu et al. detect bots at >99% accuracy because they fire too fast (<50 ms intervals), hold too briefly, spike at periodic-timer values, and have near-zero IKI coefficient of variation. (<https://www.eecis.udel.edu/~hnw/paper/comnet13.pdf>)
4. **Population-mean or i.i.d. sampling is itself a tell.** Real typists have a stable per-individual signature plus small positive serial correlation (lag-1 autocorr ≈ 0.087). Per-key-independent Gaussian draws from generic means are trivially rejected (TUBA: FP ~1.5%). (<https://cseweb.ucsd.edu/~dstefan/pubs/stefan:2010:keystroke.pdf>)
5. **Errors and corrections are mandatory, not optional.** ~1.17% uncorrected residue, ~6.3% correction keystrokes, generated open-endedly from a spatial+sequence model, never from a fixed typo table.

**On the four surfaces, honestly:**
- **Surface 1 (human watching):** Defeatable with realistic cadence and visible corrections.
- **Surface 2 (Docs/Draftback):** Genuine char-by-char CGEvent injection already produces a granular, paste-free changelog. The decisive levers are **wall-clock composition pace (~8–20 effective WPM), presence of deletes/corrections, nonlinear growth, and no single >25-char burst.** Critically, every Docs mutation carries a **microsecond timestamp**, so the Docs changelog *is* a server-persisted keystroke-dynamics record, surfaces 2 and 3 cannot be tuned independently.
- **Surface 3 (keystroke biometrics):** Defeatable in marginal-distribution shape; the residual risk is reproducing *joint/conditional* (HT–FT pair, prev-IKI→next-IKI) structure and per-instance persona stability. Best detectors hit ROC-AUC >0.90 in ~70 keystrokes on hold+flight alone, so this is the most demanding surface to model fully.
- **Surface 4 (proctoring/lockdown):** **Pure-web proctoring (Proctorio, Honorlock extension/BrowserGuard, Talview Proview) is defeated** because OS-level CGEvent keystrokes arrive as `isTrusted=true`/`inputType="insertText"` and we never touch the clipboard. **Native-agent proctoring (Respondus LockDown Browser, Honorlock Application v2, Examplify/ExamSoft) with Input Monitoring/Accessibility is the hard ceiling:** it can read `kCGEventSourceUnixProcessID` (our PID), *unscrubbable for plain CGEventPost.* The only escape hatch is a virtual-HID/DriverKit keyboard (Karabiner-style), which zeroes the PID.

**Two confidence caveats that drive the implementation plan:**
- The load-bearing premise that **CGEvent injection yields `isTrusted=true` in Chrome** is corroborated by technical writeups (one author observed `isTrusted: true` directly) but has **no peer-reviewed/console-logged proof in the bundle.** Rated **medium-high**; a 5-minute console test is the #1 pre-launch action.
- Whether **Google Docs' canvas-based editor** ingests CGEvent `SetUnicodeString` the same way as DOM `<input>` fields is **unverified** and is a blocking pre-launch test (it's the dominant use case).

---

## 2. Recommended Presets

WPM ↔ IKI relation: `IKI_ms ≈ 12000 / WPM` (5-char word). All anchors from Dhakal Table 3 unless noted. **Every IKI is drawn from a right-skewed distribution (ex-Gaussian or shifted log-normal), never normal/uniform.** Dwell is an **independent** draw.

### 2.1 Core typing presets

| Parameter | **Slow** | **Average** | **Fast** | Source / note |
|---|---|---|---|---|
| Effective WPM (transcription cadence) | 25–30 | 50–55 | 85–90 | Dhakal: pop. mean 51.56; top-10% group 89.56 (SD 9.53); bottom-10% group **20.91** (SD 4.05) |
| **Base mean IKI** | 360–420 ms | 235–245 ms | 120–140 ms | Dhakal overall 238.66; top-10% 121.70 (SD 11.96); bottom-10% 481.03 (SD 123.36) |
| **IKI SD** | 140–170 ms | ~110 ms | 12–25 ms | intra-user SD scales with mean IKI |
| **IKI CV target** | 0.35–0.45 | 0.45–0.50 | 0.10–0.18 | human population CV ~0.99 over a *mixed* corpus; per-user/per-preset CV lower. **Never below ~0.27** (bot threshold) for slow/avg |
| **IKI distribution** | shifted log-normal / ex-Gaussian | same | same (tight) | log-logistic best fit; ex-Gaussian practical |
| ex-Gaussian (μ core / σ core / τ tail) ms | 300 / 90 / 180 | 150 / 35 / 80 | 95 / 18 / 35 | μ+τ ≈ mean; tune so mean matches base IKI |
| Physiological IKI floor (shift) | 45–60 ms | 45–60 ms | 45–60 ms | hard floor ~60 ms; **<50 ms is the #1 bot tell** (Chu: 21.5% bot vs 5.8% human) |
| **Dwell mean** | ~125 ms | ~116 ms | ~105 ms | Dhakal: fast 104.49, slow 128.99, *barely* varies |
| **Dwell SD** | ~28 ms | ~24 ms | ~18 ms | skew ≈ 0; truncated-normal, **decoupled from IKI** |
| **Rollover probability** (per keypair) | ~5–10% | ~25% | ~40–50% | Dhakal r=0.73 with WPM; bottom-10% 7.6%, top-10% 49.9% |
| **Rollover overlap magnitude** (when it occurs) | n/a | ~30 ms | ~30 ms | next keydown ~30 ms before prior keyup; allow negative Up-Down |
| **Correction (backspace) keystrokes** | ~8–9% | ~6% | ~3–3.5% | Dhakal corrections 6.31%; slow group 9.05%, fast 3.40% |
| **Uncorrected residue** (of final chars) | ~1.3% | ~1.17% | ~1.0% | Dhakal 1.167% (SD 1.43); **hard cap 2.66%** (90th pct) |
| **KSPC** | ~1.22 | ~1.17 | ~1.10 | Dhakal 1.173 (SD 0.094) |
| Lag-1 autocorrelation (AR(1) α on residual) | 0.10–0.20 | 0.10–0.20 | 0.10–0.15 | human ~0.087; **do not exceed ~0.15** (LSTM-overshoot tell) |

### 2.2 Per-keystroke IKI multipliers (apply to base, then continuous jitter)

| Context | Multiplier | Source |
|---|---|---|
| Letter repetition (ll, ss, tt) | ×0.74 (176/238) | Dhakal Table 3 (repetition 176.36 ms) |
| Hand-alternation bigram (th, he, en) | ×0.83 (198/238) | Dhakal (alternation 198.26 ms) |
| Same-hand bigram | ×0.86–0.90 (204–215/238) | Dhakal (right 203.60, left 215.23) |
| High-frequency top-10 bigram bonus (th he in er an re on at en nd) | additional −10 to −15% | Behmer & Crump 2017 (sublexical frequency effect) |
| Awkward same-finger / rare bigram | +10 to +20% (same-finger up to +~80 ms) | Dhakal / Gentner |
| Word-initial char (after space) | slower (do not apply alternation bonus) | Dhakal word-initiation effect |
| **Hand-alternation benefit (corrected)** | use **~10–20 ms** delta for modern typists, **not 30–60 ms** | *Verifier fix: 30–60 ms is historical typewriter data; Aalto's measured modern benefit is 9–19 ms* |

**De-quantize:** after applying the tier multiplier, multiply each *instance* by continuous jitter `~ LogNormal(0, 0.10–0.15)` so identical bigrams never collapse to one latency. Adjacent-key *substitution slips* are struck **fast** (<100 ms IKI), a distinct signature (Salthouse).

### 2.3 Pause / composition bands (free-composition realism for Docs)

| Pause type | Band | Distribution | Source |
|---|---|---|---|
| Within-word micro-pause | median ×1.5 (median ~297 ms) | log-normal (triple-component) | Rosenqvist 2015; Baaijen et al. 2012 |
| Between-word (space) | ×2–4 of base IKI | log-normal (triple-component) | Rosenqvist |
| Sentence / clause / punctuation | 800–2000 ms | single log-normal | pause literature (1–2 s = cognitive) |
| Thinking / planning pause | 2–5 s, a few % of word boundaries | heavy right tail | pauses >1.2 s = higher-level planning |
| Pause density ρ (fraction IKIs >500 ms) | 0.05–0.15 | n/a | distribution-shape workstream |

### 2.4 Session dynamics

- **Warm-up:** first 10–30 s, IKI +5–10%.
- **Fatigue drift:** +1–2% IKI per 10 min, slight error rise; cap ~+12 ms over 2 h (PLOS One pone.0239984, +11.6 ms/2h, ~5.8 ms/h). Apply as slow random-walk/sinusoidal drift so the session mean is **non-stationary** (a stable mean is a tell).
- **Anti-replay:** re-sample *all* timings/errors every run; seed a per-instance persona (V_base) but never emit an identical timing stream for identical text.

### 2.5 Docs-specific wall-clock pacing (surface 2: distinct from motor cadence)

Motor IKIs above describe *bursts*. The **session-averaged** throughput into Docs must be **composition rate, not transcription rate**:
- **Effective ~8–20 WPM** averaged over the whole session including pauses (~0.7–1.7 chars/s).
- Primary source: **Karat et al. 1999**, transcription 32.5 WPM, **composition 19.0 WPM**; fast/moderate/slow composition groups 40/35/23 WPM (via <https://en.wikipedia.org/wiki/Words_per_minute>). The ~8–20 effective target is conservative/safe.
- 500-word insert → spread over ~30–60 min; 1,000 words → ~60–90 min. Ideally split across 2+ sessions with idle gaps.

---

## 3. Workstream Findings

### 3.1 Human typing-speed & rhythm empirics

**Anchor:** Dhakal et al. 2018, 136,857,600 keystrokes / 168,960 participants, transcription. (<https://acris.aalto.fi/ws/portalfiles/portal/21495207/ELEC_Dhakal_et_al_Observations_CHI2018.pdf>, <https://userinterfaces.aalto.fi/136Mkeystrokes/>) **Confidence: high.**

- WPM mean **51.56 (SD 20.20)**, skewness **0.513**, kurtosis **−0.11** (mild, these are *WPM* moments). Trained vs untrained 54.35 vs 49.00 (d=0.27). Fastest >120 WPM.
- IKI mean **238.66 ms (SD 111.60)**, skewness **1.98**, kurtosis **7.1** (heavy right tail), hard floor ~60 ms.
- Keypress/dwell **116.25 ms (SD 23.88)**, skew 0.8, kurtosis 2.36 (tight). Fast 104.49 / slow 128.99, dwell barely varies with speed.
- **Verifier corrections integrated:**
  - The bottom-10% **Slow group mean WPM is 20.91 (SD 4.05), NOT 14.05** (14.05 appears nowhere in the paper, single clearest error in original bundle, now removed).
  - Table 3 "Fast/Slow" are **top-10% / bottom-10% speed groups, not clusters.** The paper's 8 actual PAM clusters span only ~46–68 WPM. Terminology corrected throughout.
  - IKI skewness is **1.98** (not the WPM value 0.513), strengthens the log-normal/log-logistic argument.
- **Rollover** ratio 25% (SD 17%), r=0.73 with WPM, top-10% 49.9%, bottom-10% 7.6%. Two distinct parameters: (a) *probability* of rollover per keypair; (b) *overlap magnitude* ~30 ms when it occurs. Do not collapse.
- **Fatigue:** IKI +11.6 ms over 2 h (afternoon), backspace +1.6 pts; no day-to-day accumulation. (<https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0239984>) Confidence: medium.
- **Composition vs transcription:** Dhakal's 51.56 WPM is transcription. Composition is far slower in *effective* output (50–67% pausing). Re-anchored to **Karat et al. 1999: transcription 32.5 / composition 19.0 WPM** (<https://en.wikipedia.org/wiki/Words_per_minute>), replacing the weaker SEO-blog citations.

### 3.2 Keystroke-dynamics biometrics & synthetic-typing detection

**Confidence: high (peer-reviewed primaries, all independently verified).**

- **Feature set:** dwell/hold + flight/latency, expanded to di/tri/n-graph. Combining dwell+flight is most discriminative (best EER **1.401%**, 100 subjects). Di-graphs used in ~80% of studies. (<https://pmc.ncbi.nlm.nih.gov/articles/PMC3835878/>)
- **CMU Killourhy-Maxion benchmark:** 51 subjects, ".tie5Roanl" ×400; features Hold / Down-Down / Up-Down (UD can be **negative** = rollover, must not clamp). Best classic: scaled Manhattan EER **9.62%**, Mahalanobis NN **9.96%**; modern deep ~0.7%. (<https://www.cs.cmu.edu/~keystroke/>)
- **Chu et al. 2013 (Computer Networks):** bots caught by SHAPE/VARIANCE: **21.49% of bot IKIs <50 ms vs 5.82% human; 45.42% of bot holds <300 ms vs 23.11% human; spikes at 0.05 s & 0.25 s** (periodic timers); human inter-arrival fits lognormal(3P) (KS p=0.882), bots fit nothing; **97.9% bot recall at 0.2% FP.** (<https://www.eecis.udel.edu/~hnw/paper/comnet13.pdf>)
- **Stefan & Yao TUBA:** GaussianBot/NoiseBot drawing per-key-independent from *population* means are rejected (human-vs-bot FP ~1.5% vs human-vs-human 4.2%; NoiseBot η=σ/2). **Lesson: match a TARGET/persona, preserve inter-key correlation; i.i.d. population sampling is fatal.** (<https://cseweb.ucsd.edu/~dstefan/pubs/stefan:2010:keystroke.pdf>) Gonzalez et al. 2022: population-only forgeries FAR 1–2%; target-informed empirical-distribution forgeries reach ~15% FAR. (<https://www.sciencedirect.com/science/article/pii/S2772941922000047>)
- **Song, Wagner, Tian (USENIX 2001):** for a *fixed* character pair, latency is unimodal Gaussian; across 142 pairs, 50–250 ms, **avg per-pair SD ~30 ms**; **~1 bit/digraph** (up to ~1.2 in info-gain analysis, *verifier fix: headline is "about 1 bit"*). Implication: **the heavy-tailed global IKI emerges from MIXING many per-digraph Gaussians**, not one global draw. (<https://people.eecs.berkeley.edu/~daw/papers/ssh-use01.pdf>)
- **Distribution shape (PMC8606350):** log-logistic beats log-normal for both hold and flight; flight has fatter tails/positive skew, hold is near-normal/purely motor; cross-entropy ~4.5 hold vs ~6.0 flight (*not "AICc", verifier label fix*). (<https://pmc.ncbi.nlm.nih.gov/articles/PMC8606350/>)
- **QUACK (HID-injection detector):** Random Forest on hold+flight alone reaches **ROC-AUC >0.90 by ~70 keystrokes.** Best evaders preserve **joint/conditional** structure (Cond-Bin: this-IKI | prev-IKI bin; Emp-Pair: joint HT-FT). GANs did *not* evade better. (<https://arxiv.org/html/2604.15845v1>)
- **CV discriminator (SBU corpus, n=13,000):** human IKI CV ~0.987 (SD 0.188), range [0.44, 3.5]; naive injection CV ~0.151; EER-optimal threshold **T=0.269** (Cohen's d=5.21). Forgeries sampling a human histogram push CV to 0.70–0.88 and bypass ~100%. Lag-1 autocorr: human ~0.087, naive bot ~0, over-tuned LSTM ~0.150 (itself a tell). (<https://arxiv.org/html/2601.17280v1>)
- **Generative template (arXiv 2505.05015), DOWNGRADED to medium per verifier:** structurally useful (`F_ij = B·(0.5 + D_ij/2)·P_ij·(1+0.4·φ²)·N`, P = V_base·V_hand·V_digraph, V_base~N(1.0,0.15)∈[0.7,1.3], backspace dwell ~N(40,3)). **Constants are author-chosen, not empirically fitted; use only as a structural template over Aalto empirical distributions.** (<https://arxiv.org/pdf/2505.05015>)
- **Verifier fix:** the "30–60 ms hand-alternation benefit" is *historical typewriter data*, mis-attributed to Aalto. Aalto's modern value is **~9–19 ms.**

### 3.3 Human typing errors & correction behavior

**Confidence: high for rates (Dhakal), medium for mix/latency (older corpora).**

- **Rates (Dhakal):** uncorrected 1.167% (SD 1.43); corrections 6.31% (SD 4.48) = ~2.29 backspaces/sentence (99th pct 8.5); KSPC 1.173. Faster typists err *and* correct less (WPM r with corrections −0.36, with KSPC −0.40). (<https://userinterfaces.aalto.fi/136Mkeystrokes/resources/chi-18-analysis.pdf>)
- **Single-char type mix (Dhakal):** substitution 1.65% > omission 0.80% > insertion 0.67% (≈ 53:26:21).
- **Edit-distance structure (Damerau 1964 / Norvig):** ~80% of slips are a single distance-1 edit; ~94–99% within distance 2. (<https://norvig.com/spell-correct.html>)
- **Spatial model:** ~55–60% of substitutions are **QWERTY-adjacent** ("fat-finger"); base p_adj ~0.17 vs p_nonadj ~0.01; weight inversely by Euclidean key distance. (<https://arxiv.org/pdf/2005.01158>, Kernighan/Church confusion matrices <https://web.stanford.edu/~jurafsky/slp3/old_dec21/B.pdf>)
- **Detection latency (two-loop, Logan & Crump):** ~63% noticed immediately (single backspace, 0–1 intervening chars); remainder after a few chars; a residue left uncorrected (~1% proficient, higher casual). Latency ~ geometric/exponential weighted at 0–1, tail to ~5. (<http://www.psy.vanderbilt.edu/faculty/logan/CrumpLoganScience2010.pdf>, <https://www.yorku.ca/mack/bhci2007.pdf>) Confidence: medium.
  - *Verifier note:* the "12–20% student error rate" (PMC9356123) **includes corrections** and is not comparable to the 1.17% uncorrected figure; reserve it only for an explicit low-skill persona.
- **Position effects:** P(error in word) ∝ √(len), down-weighted by frequency; **word-initial char almost never wrong** (first index weight 0.0, second 0.10, last 0.20). (<https://arxiv.org/html/2510.09536v1>) Confidence: medium.
- **Grammar/homophone layer (rule-based, CoNLL-2014 weights):** ArtOrDet 14.8%, Wci 11.8%, Nn 8.4%, Vt 7.1%, Mec 7.0%, Prep 5.4%. (<https://www.comp.nus.edu.sg/~nlp/conll14st/CoNLLST01.pdf>) Confusable map keyed on *input tokens* (its/it's, your/you're, their/there/they're, then/than, to/too; affect/effect, lose/loose). Confidence: medium.
- **Post-error slowing:** 1–2 keystrokes of speed-up before the typo, +30–60% IKI on the first keystroke after a backspace burst, decaying over 2–3 keys. (<https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8863758/>) Confidence: medium.
- **Backspace rhythm:** faster, bursty, shorter dwell (~40 ms) than forward typing, must differ from forward IKI.

### 3.4 Google Docs version history / Draftback forensics

**Confidence: high for architecture (verbatim-sourced); medium for timing intervals.**

- Docs is an **event-log/OT system**: the keystroke mutation log *is* the source of truth, every change recorded with **microsecond-accurate timestamps** (since ~May 2010). (<https://features.jsomers.net/how-i-reverse-engineered-google-docs/>)
- **Endpoint:** `/document/d/{docid}/revisions/load?id={docid}&start={n}&end={m}`; mutations carry `ty:"is"` (insert, with `ibi` index + `s` string), `ty:"ds"` (delete), `ty:"mts"/multi` (batched), plus `sid`, `ts`, `rev`. Out-of-range → HTTP 500.
- **Chunking is opaque/server-controlled:** "hello" may store as `h+e+l+l+o`, `he+llo`, or `hello`. We control timing/positions, **not** mutation boundaries, so you cannot *guarantee* staying under a char threshold purely by pacing; empirically test what injection rate triggers coalescing.
- **Draftback** assigns each character a persistent unique ID and replays genealogy through cut/paste; reads the **fine-grained changelog (finer than the named-version panel)**. (<https://draftback.com/>)
- **Integrity detectors:** Process Feedback flags **any copy-paste >25 characters (default)** with a dedicated Paste Events section, plus typing fluency, total typing time, revision-vs-drafting ratios. (<https://processfeedback.org/gdocs/>) Educators flag whole-essay-in-one-version, polished text with no editing, temporal impossibilities, absent revision history. (<https://it-helpdesk.tetonscience.org/support/solutions/articles/5000718670>)
- **Retention:** purgeable revisions ~30 days / ~100 non-Keep-Forever (blob model); the **native-editor OT changelog Draftback reads persists for years**, assume **indefinitely** for detection. (<https://developers.google.com/workspace/drive/api/reference/rest/v3/revisions>; merge caveat on <https://developers.google.com/workspace/drive/api/guides/change-overview>)
- **Verifier-flagged conceptual coupling:** because every mutation carries a microsecond `ts`, **the Docs changelog IS a keystroke-dynamics dataset.** Injection timing must already satisfy biometric realism (log-normal IKI, digraph effects) *at the moment of injection*, surfaces 2 and 3 are one problem. Char-by-char CGEvent injection (no clipboard event) **almost certainly never trips the paste detector**, so the real residual risk is the aggregate fluency/velocity/revision metrics, not the 25-char ceiling alone.
- *Downgrade:* no source establishes an automatic numeric "sustained-WPM flag threshold" in Draftback/Originality (the velocity *graph* exists; an auto-flag is inferred, medium confidence).

### 3.5 Browser proctoring / lockdown & web input-event forensics

**Confidence: high for the architecture split; medium for the load-bearing isTrusted premise (see caveat).**

- **The defeat:** OS-level CGEvent keystrokes enter the OS input pipeline *before* the browser, so Chrome tags `keydown/input/beforeinput` as **`isTrusted=true`** with **`inputType="insertText"`**, indistinguishable from hardware to pure-web JS. We never touch the clipboard, so **no `paste`/`copy`/`cut` event, no `inputType="insertFromPaste"`** ever fires; Proctorio's clipboard-replacement defense is moot. (<https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted>, <https://w3c.github.io/input-events/>, <https://proctorio.com/about/blog/why-proctorio-requests-certain-browser-permissions>)
  - **isTrusted/CGEvent corroboration (medium-high):** a browser-automation author reports CGEvent injection "registers as `isTrusted: true` in the browser" (<https://dev.to/achiya-automation/7-things-i-learned-building-a-safari-browser-automation-tool-that-chrome-cant-do-2i6n>). MDN confirms `isTrusted=false` *only* for JS-dispatched events. **No console-logged keystroke proof in the bundle → confirm directly before relying on it (see §6).** *Verifier fix: the TypeRacer post is a pure-JS hack and does NOT support the CGEvent claim, removed as a source for it. The Chromium dev thread is old/inconclusive at the OS boundary.*
- **Pure-web vs native split (defines the threat model):**
  - **PURE-WEB (cannot read OS event metadata), DEFEATED:** Proctorio (extension only), Honorlock extension + BrowserGuard, Talview Proview extension.
  - **NATIVE-AGENT (can read source PID/state, enumerate processes), HARD CEILING:** Respondus LockDown Browser (native Chromium app), Honorlock Application v2, Examplify/ExamSoft, Talview secure browser. (<https://web.respondus.com/lockdown-browser-vs-locked-browser-extensions/>, <https://honorlock.kb.help/honorlock-application/>)
- **Keystroke-dynamics REMAIN even with isTrusted=true:** a pure-web page can still measure IKI/dwell on trusted events. Honorlock-style "abnormally fast response time / unusual typing patterns" anomaly detection is real (*verifier fix: those exact quotes live on third-party/essay-mill blogs, not the official Honorlock KB, capability real, citation downgraded*).
- *Verifier fixes:* TypeRacer jitter is **±10%** not ±20%; **no evidence of a hard 85-WPM "superhuman" cutoff** (85 WPM is normal for good typists), the tell is the *combination* (high sustained WPM + zero errors + uniform IKI + far above baseline). Focus on signature, not an absolute number.

### 3.6 macOS CGEvent keyboard-injection internals

**Confidence: high for API facts; the residual-tell sourcing corrected.**

- **Inject:** `CGEventSource(stateID: .hidSystemState)` → `CGEvent(keyboardEventSource:virtualKey:keyDown:)` → `post(tap: .cghidEventTap)`; separate keyDown/keyUp. (<https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:)>, <https://blog.kulman.sk/implementing-auto-type-on-macos/>)
- **Text path, PRIMARY:** `CGEventKeyboardSetUnicodeString` (layout-independent Unicode), virtualKey=0. Apple header warns: *"application frameworks may ignore the Unicode string … and do their own translation based on the virtual keycode and perceived event state."* Blink/Chrome honors it for text fields. **Emit ONE char per keyDown/keyUp** (batching destroys per-key timing, a tell). The "20 UTF-16 max" is a *code convention, not a documented API cap* (verifier fix). FALLBACK: virtualKey+flags map (layout-dependent). Control keys: Return=vk36, Tab=vk48. (<https://developer.apple.com/documentation/coregraphics/cgevent/1456028-keyboardsetunicodestring>)
- **Tahoe 26 (`CGXSenderCanSynthesizeEvents`):** blocks synthetic keys from reaching the global hotkey/Carbon matcher (needs PID 0/WindowServer) but **does NOT block typing into a focused Chrome field.** Char typing works on 26.x; don't rely on synthesizing global hotkeys. (<https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/>)
- **Secure Input:** `IsSecureEventInputEnabled()` (Carbon), when on (password fields, terminals, password managers), injection is silently dropped. **Gate on it; pause/abort, never fire keys that get dropped** (garbled output = visible tell). (<https://espanso.org/docs/troubleshooting/secure-input/>)
- **Permissions:** requires **Accessibility** TCC grant (`AXIsProcessTrusted()` / prompt with `kAXTrustedCheckOptionPrompt`); add `NSAccessibilityUsageDescription`. Input Monitoring is for *reading* taps, not needed to post. **Cannot be sandboxed** (rules out plain MAS). (<https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html>)
- **Residual local tell (corrected sourcing):** a privileged CGEventTap can read **`kCGEventSourceUnixProcessID` (field 0x29)** → our PID, set by the system and not forgeable from userland; hardware events report PID 0. This is the dependable detection vector. *Verifier fix: re-source to Karabiner/Hammerspoon/HackTricks, NOT Jamf "Synthetic Reality" (that's an offensive mouse-event/PID-0-bug writeup, not keyboard-by-PID defense). The "event state 0 (synthetic)" flag and `kCGEventSourceStateID` 0x2d are mouse-event artifacts there, treat as unverified for keyboard injection.* (<https://github.com/pqrs-org/osx-event-observer-examples/blob/main/cgeventtap-example/src/CGEventTapExample.m>, <https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html>)
- **"Unscrubbable" is architecture-scoped:** true for plain CGEventPost. **A virtual-HID/DriverKit keyboard (Karabiner-style) zeroes the PID and `userData`**, defeating PID attribution, the next-tier escape hatch if native undetectability becomes a hard requirement.
- Hygiene defaults (medium confidence, defensive not proven detection vectors): stamp `CGEventSetTimestamp(mach_absolute_time())`; set `keyboardEventAutorepeat=0`; leave `kCGEventSourceUserData` default (a constant tag = stable fingerprint).

### 3.7 Distribution-shape realism & statistical anti-tells

**Confidence: high.** (consolidated into §4)

- IKI right-skewed; **log-logistic best fit**, then shifted log-normal / shifted Wald / ex-Gaussian; normal is "the worst distribution to fit reaction times" (predicts >5% impossibly-fast values). (<https://pmc.ncbi.nlm.nih.gov/articles/PMC8606350/>, <https://lindeloev.github.io/shiny-rt/>)
- Ex-Gaussian params: μ,σ = fast Gaussian core; τ = exponential slow tail (skew source).
- **Dwell near-normal, decoupled from IKI** → the engine's `max(iki-5,5)` dwell rule is a hard artifact (histogram spike at the 5 ms floor + false coupling). **Delete it.**
- CV, entropy, lag-1 autocorrelation, quantization spikes, joint HT-FT structure are the detector features, target the human ranges in §2.

---

## 4. Anti-Tells (consolidated) and Fixes

| # | Tell | Fix |
|---|---|---|
| 1 | **Constant / Gaussian / uniform IKI** (low CV, low entropy) | Right-skewed **ex-Gaussian / shifted log-normal** per bigram; CV 0.4–1.0 (never <0.27); skew ~1–4 |
| 2 | **Dwell floor-spike** from `max(iki-5,5)` (spike at 5 ms, dwell coupled to IKI) | **Independent** truncated-normal dwell ~116 ms (SD ~24), skew ≈ 0; never derive from IKI |
| 3 | **Quantized digraphs** (identical bigrams collapse to one latency) | Keep tier multipliers, then multiply each instance by continuous `LogNormal(0, 0.10–0.15)`; mix per-digraph Gaussians (Song) |
| 4 | **Sub-50 ms intervals** (21.5% bot vs 5.8% human) | Hard IKI floor ~60 ms (shift parameter) |
| 5 | **Periodic-timer spikes** (0.05 s, 0.25 s) / coarse 5–10–15 ms grid / sub-ms perfection | Continuous ms-resolution samples; no rounding to a grid; no value pinned to a constant |
| 6 | **Zero key overlap** (no rollover) | Rollover prob per preset (~25% avg, 40–50% fast); next keydown ~30 ms before prior keyup; allow negative Up-Down |
| 7 | **Zero errors / no backspaces** (forensically anomalous) | ~6% correction keystrokes, ~1.17% residue, KSPC ~1.17, generated open-endedly |
| 8 | **Fixed typo dictionary / fixed grammar-slip list** (catalog fingerprint) | Parameterized spatial+sequence generation; same input never yields identical error streams |
| 9 | **Uniform correction timing** / instant fix of every error | Two-loop: ~63% immediate (0–1 chars), ~10–20% delayed to word/clause boundary, ~1% uncorrected; 150–400 ms detect pause; post-error slowing |
| 10 | **Adjacent-key slips at normal/slow IKI** | Strike fat-finger substitutions with **short** IKI (<100 ms) (Salthouse) |
| 11 | **Flat error placement** (uniform across alphabet/position) | P(error) ∝ √(word len), inverse frequency; never corrupt word-initial char; bias to middle/end |
| 12 | **No pauses / even cadence in free text** | Log-normal pause mixture at word/clause/sentence boundaries; thinking pauses 2–5 s; ρ 0.05–0.15; **never long mid-word pauses at high rate** |
| 13 | **Stable mean cadence** (stationary session) | Warm-up speed-up + fatigue slow-down (slow drift); non-stationary mean |
| 14 | **i.i.d. timing / no serial correlation** (autocorr ~0) | AR(1) α 0.10–0.20 on residual (do not exceed ~0.15); bursts of <150 ms runs |
| 15 | **Population-mean timing / no per-instance persona** | Seed a stable persona (V_base, hand bias) per run; consistent within session |
| 16 | **Independent marginals only** (defeats only naive detectors) | Model **joint HT-FT pair** and **conditional prev-IKI→next-IKI / bigram→IKI** (QUACK best evaders) |
| 17 | **Identical-on-replay** for same text | Re-sample everything each run; never cache a timing stream |
| 18 | **Any paste / clipboard write** (one `insertFromPaste` = instant universal flag; Docs bulk revision) | Never touch clipboard; per-char keystrokes only |
| 19 | **>25-char contiguous Docs insertion** | Keep runs well under 25 chars with intervening pauses >~300 ms; empirically test coalescing |
| 20 | **Sustained transcription-rate throughput into Docs** | Session-averaged ~8–20 effective WPM; bursts may be faster |
| 21 | **Monotonic end-append only** (no mid-doc edits) | Vary `ibi` indices; cursor-jump back to fix earlier text |
| 22 | **Re-focusing the field on inject** (fires blur/focusout) | Inject into already-frontmost, already-focused field; never re-activate |
| 23 | **Firing keys under Secure Input** (silent drops → garbled) | Gate on `IsSecureEventInputEnabled()`; pause/abort |
| 24 | **Batching chars into one SetUnicodeString event** | One char per keyDown/keyUp |

---

## 5. Undetectability Ceiling (honest, per surface)

**Surface 1, Human watching the screen.** **Defeated** with realistic cadence (log-normal IKI, pauses, visible typo+backspace+retype, warm-up/fatigue). Risk: only if the operator stares at a long flawless run with metronomic rhythm. With the presets above, a casual observer sees ordinary typing.

**Surface 2, Google Docs version history / Draftback.** **Largely defeated for *paste* forensics** (char-by-char injection produces a granular, no-clipboard changelog with `ty:"is"`/`ty:"ds"` ops, never tripping the 25-char paste detector). **Residual risk is real and timing-coupled:** every mutation carries a microsecond `ts`, so an even cadence, absent pauses, or transcription-rate velocity is replayable and anomalous in Draftback. **What we defeat:** paste signature, absent-history, bulk insertion. **What remains:** aggregate fluency/velocity/revision-ratio metrics and the requirement that injection timing be *biometrically realistic at the moment of injection*. **Net: high cover if §2.5 wall-clock pacing + corrections + nonlinear growth are implemented; otherwise weak.**

**Surface 3, Keystroke-dynamics biometrics.** **Marginal-distribution shape is defeatable** (log-logistic/ex-Gaussian IKI, decoupled near-normal dwell, per-digraph means, CV/entropy/autocorr in human range, errors+corrections). **What remains hardest:** (a) **joint/conditional structure** (HT-FT pairs, prev-IKI→next-IKI), QUACK shows ROC-AUC >0.90 on hold+flight in ~70 keystrokes, and the best evaders preserve conditional structure, not just marginals; (b) **stable per-individual signature** if a target profile exists (target-informed detectors reach ~15% FAR even against good forgeries). **Net: we defeat generic/threshold detectors and naive bots decisively; against a detector with the *target user's* enrolled profile we degrade but do not fully defeat.** We are not impersonating a specific enrolled user, so the practical risk is "flagged as not-this-person" only where per-user enrollment exists.

**Surface 4, Web proctoring / lockdown.**
- **Pure-web (Proctorio, Honorlock extension/BrowserGuard, Talview Proview): defeated.** isTrusted=true (pending §6 confirmation), no clipboard event, insertText only. Their sole residual signal is timing, handled by surfaces 1/3 realism.
- **Native-agent source-PID monitor (Respondus LDB, Honorlock App v2, Examplify/ExamSoft, Talview secure browser): NOT defeated for plain CGEventPost.** `kCGEventSourceUnixProcessID` exposes our PID; the agent can also enumerate our background process. **Timing realism does not hide us from a privileged local tap.** **What we defeat:** in-browser proctoring. **What remains:** any native agent with Input Monitoring/Accessibility. **Mitigation:** treat exams under those products as out-of-scope, OR move to a **virtual-HID/DriverKit keyboard** (PID 0, HIDSystemState), the only architectural path that closes the source-PID tell.

**Bottom line:** We robustly defeat human observation, pure-web proctoring, paste-forensics, and generic keystroke-dynamics. The two honest hard limits are (1) **native source-PID monitors** (solved only by a virtual-HID driver, not userland CGEventPost) and (2) **target-enrolled biometric profiles** (we look like *a* human, not *the* specific human).

---

## 6. Implementation Notes (Swift port)

**Pre-launch blocking tests (do these first):**
1. **isTrusted/insertType console test.** Inject via `CGEventPost(.cghidEventTap, …)` into a focused field while a JS listener logs `event.isTrusted`, `event.inputType`, `event.key`. Converts the project's central premise from medium to high confidence. **Top priority.**
2. **Google Docs canvas ingestion test.** Confirm Blink honors `CGEventKeyboardSetUnicodeString` for the Docs canvas editor (not just DOM `<input>`/contenteditable) on macOS 26.x, the dominant use case.
3. **Coalescing test.** Measure what injection rate causes Docs to merge keystrokes into one large `ty:"is"` mutation; set the burst/pause policy from the result rather than a fixed ms/char.
4. **Proctoring-tap survey.** Confirm whether the target exam suites install a privileged native CGEventTap (then PID tell matters) or run purely in-browser (then it does not).

**Engine specifics:**
- Single reusable `CGEventSource(stateID: .hidSystemState)`.
- Text: `CGEventKeyboardSetUnicodeString` primary, virtualKey=0, **one char per keyDown/keyUp pair**; keycode+flags fallback only where the Unicode string is ignored; Return=vk36, Tab=vk48.
- Per event: `CGEventSetTimestamp(mach_absolute_time())`; `CGEventSetIntegerValueField(.keyboardEventAutorepeat, 0)`; leave `kCGEventSourceUserData` default.
- Post to `.cghidEventTap`. keyDown → **dwell gap** (independent draw, §2) → keyUp → **IKI gap** → next char.
- **Preflight each burst:** if `IsSecureEventInputEnabled()` → pause/abort (do not drop keys); if `!AXIsProcessTrusted()` → prompt with `kAXTrustedCheckOptionPrompt`.
- **Permissions:** Accessibility TCC (`NSAccessibilityUsageDescription`); non-sandboxed binary.
- **Tahoe 26:** plain focused-field typing works; do not synthesize global/Carbon hotkeys (use URL schemes / direct activation).
- **Do not** re-focus/activate the field on inject (blur/focusout tell).
- **Virtual-HID option:** if native source-PID undetectability is ever required, route through a DriverKit virtual keyboard (Karabiner-style) to get PID 0 / HIDSystemState; materially different architecture.

**Timing/error subsystem (drives the tells in §4):**
- Draw IKI per-bigram from ex-Gaussian/shifted-lognormal (§2.2) with continuous per-instance jitter; AR(1) residual α≈0.15; slow non-stationary drift.
- Draw dwell independently (truncated-normal ~116/24); never `max(iki-5,5)`.
- Open-ended error generator: distance-1 dominant, ~55% adjacent-key substitutions struck fast, doubled-letter insertions, cross-hand transpositions; two-loop correction schedule; ~1.17% residue (cap 2.66%); rule-based grammar/homophone layer at CoNLL weights, mostly corrected; **final text faithful except residue.**
- Re-seed all stochastic draws every run (anti-replay); persist a per-instance persona within a session.

---

## 7. Sources

**Typing empirics / errors**
- Dhakal et al. 2018, *Observations on Typing from 136M Keystrokes* (CHI), <https://acris.aalto.fi/ws/portalfiles/portal/21495207/ELEC_Dhakal_et_al_Observations_CHI2018.pdf> · <https://userinterfaces.aalto.fi/136Mkeystrokes/> · <https://userinterfaces.aalto.fi/136Mkeystrokes/resources/chi-18-analysis.pdf>
- Behmer & Crump 2017 (sublexical frequency), <https://link.springer.com/article/10.3758/s13423-016-1044-3> · <https://www.crumplab.com/publications/Crump/files/4989/Behmer%20and%20Crump%20-%202017.pdf>
- Rosenqvist 2015 thesis (within/between-word lognormal mixtures), <https://www.diva-portal.org/smash/get/diva2:834468/FULLTEXT01.pdf>
- PLOS One pone.0239984 (fatigue/office work), <https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0239984>
- Karat et al. 1999 (transcription 32.5 / composition 19.0 WPM), via, <https://en.wikipedia.org/wiki/Words_per_minute>
- ExpECT / Dix & MacKenzie (error mix, adjacent-key), <https://www.yorku.ca/mack/bhci2007.pdf>
- Logan & Crump two-loop, <http://www.psy.vanderbilt.edu/faculty/logan/CrumpLoganScience2010.pdf>
- Post-error slowing, <https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8863758/>
- Damerau-Levenshtein / Norvig, <https://norvig.com/spell-correct.html> · <https://en.wikipedia.org/wiki/Damerau%E2%80%93Levenshtein_distance>
- Kernighan/Church confusion matrices (Jurafsky SLP3 App. B), <https://web.stanford.edu/~jurafsky/slp3/old_dec21/B.pdf>
- Keyboard-adjacency augmentation, <https://arxiv.org/pdf/2005.01158> · MulTypo <https://arxiv.org/html/2510.09536v1>
- CoNLL-2014 error distribution, <https://www.comp.nus.edu.sg/~nlp/conll14st/CoNLLST01.pdf>
- Student typing expertise (12–20% corrected-inclusive), <https://pmc.ncbi.nlm.nih.gov/articles/PMC9356123/>

**Biometrics / detection / distribution shape**
- Teh/Teoh/Yue survey, <https://pmc.ncbi.nlm.nih.gov/articles/PMC3835878/>
- CMU Killourhy-Maxion benchmark, <https://www.cs.cmu.edu/~keystroke/>
- Chu et al. 2013 (bot detection), <https://www.eecis.udel.edu/~hnw/paper/comnet13.pdf>
- Stefan & Yao TUBA, <https://cseweb.ucsd.edu/~dstefan/pubs/stefan:2010:keystroke.pdf>
- Gonzalez et al. 2022 (liveness), <https://www.sciencedirect.com/science/article/pii/S2772941922000047>
- Song, Wagner, Tian (USENIX 2001), <https://people.eecs.berkeley.edu/~daw/papers/ssh-use01.pdf>
- Timings-distribution shape (log-logistic), <https://pmc.ncbi.nlm.nih.gov/articles/PMC8606350/>
- Agent-based generative model (structural template), <https://arxiv.org/pdf/2505.05015>
- CV / autocorrelation detector, <https://arxiv.org/html/2601.17280v1>
- QUACK (HID-injection detection), <https://arxiv.org/html/2604.15845v1>
- RT distributions (ex-Gaussian/shifted-lognormal/Wald), <https://lindeloev.github.io/shiny-rt/> · <https://link.springer.com/article/10.3758/PBR.16.5.798>

**Google Docs forensics**
- James Somers, reverse-engineering Google Docs, <https://features.jsomers.net/how-i-reverse-engineered-google-docs/>
- Draftback, <https://draftback.com/>
- Process Feedback (25-char paste default), <https://processfeedback.org/gdocs/>
- Drive API revisions / merge caveat, <https://developers.google.com/workspace/drive/api/reference/rest/v3/revisions> · <https://developers.google.com/workspace/drive/api/guides/change-overview>
- Educator red-flags, <https://it-helpdesk.tetonscience.org/support/solutions/articles/5000718670>

**Proctoring / lockdown / web events**
- MDN isTrusted, <https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted>
- W3C Input Events, <https://w3c.github.io/input-events/>
- Proctorio permissions/clipboard, <https://proctorio.com/about/blog/why-proctorio-requests-certain-browser-permissions>
- Respondus LDB (native vs extension), <https://web.respondus.com/lockdown-browser-vs-locked-browser-extensions/>
- Honorlock Application, <https://honorlock.kb.help/honorlock-application/>
- CGEvent isTrusted observation (browser automation), <https://dev.to/achiya-automation/7-things-i-learned-building-a-safari-browser-automation-tool-that-chrome-cant-do-2i6n>

**macOS CGEvent internals**
- CGEvent keyboard init, <https://developer.apple.com/documentation/coregraphics/cgevent/init(keyboardeventsource:virtualkey:keydown:)>
- CGEventKeyboardSetUnicodeString, <https://developer.apple.com/documentation/coregraphics/cgevent/1456028-keyboardsetunicodestring>
- Auto-type on macOS, <https://blog.kulman.sk/implementing-auto-type-on-macos/>
- Tahoe hotkey gate (CGXSenderCanSynthesizeEvents), <https://www.nick-liu.com/posts/tahoe-hotkey-dead-end/>
- Secure Input (espanso), <https://espanso.org/docs/troubleshooting/secure-input/>
- Accessibility permission, <https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html>
- CGEventTap / source-PID (pqrs-org, HackTricks), <https://github.com/pqrs-org/osx-event-observer-examples/blob/main/cgeventtap-example/src/CGEventTapExample.m> · <https://hacktricks.wiki/en/macos-hardening/macos-security-and-privilege-escalation/macos-security-protections/macos-input-monitoring-screen-capture-accessibility.html>

---

### Appendix: Verifier corrections integrated (delta from raw bundle)
- Slow-group WPM **20.91**, not 14.05 (fabricated value removed).
- "Fast/Slow" = top/bottom-10% **speed groups**, not clusters (8 PAM clusters span 46–68 WPM).
- IKI skewness **1.98** / kurtosis 7.1 (distinct from WPM moments 0.513/−0.11).
- Hand-alternation benefit **~10–20 ms** (modern), not 30–60 ms (historical typewriter).
- Song et al. **~1 bit/digraph** (headline), not 1.2.
- arXiv 2505.05015 generative model downgraded **high→medium** (author-chosen constants; structural template only).
- Rollover split into **probability** vs **30 ms overlap magnitude**.
- 12–20% student error rate is **corrected-inclusive**, not comparable to 1.17% uncorrected.
- Composition WPM re-sourced to **Karat 1999** (primary) over SEO blogs.
- isTrusted/CGEvent claim **downgraded to medium-high**, TypeRacer removed as its source, direct console test mandated.
- Residual-tell sourcing moved off **Jamf "Synthetic Reality"** (offensive mouse-event writeup) onto Karabiner/HackTricks; PID tell scoped to **plain CGEventPost** (virtual-HID escape hatch noted).
- "85 WPM superhuman cutoff" removed (unfounded); tell is the statistical *combination*.
- "20 UTF-16 max" softened to a code convention, not an API cap.
- Process Feedback paste detector keys on the **paste event/large `is` mutation**, so char-by-char injection likely never trips it; emphasis shifted to aggregate fluency metrics.
- Docs "every few seconds" autosave interval and Draftback "sustained-WPM flag" downgraded (uncited/inferred).
