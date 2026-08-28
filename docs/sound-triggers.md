# Alert sounds: how I'm Burning! triggers them (port reference)

Reference for porting the three alert sounds into Multimodel Tracker. Everything
below is transcribed from the working implementation in `~/burnwatch`
(`src/renderer/app.js` for triggers/playback, `main.js` for the burn detector).

## The three sounds

| Event | Sound file (canonical copy) | Length |
|---|---|---|
| Burning tokens quickly (burn-spike detector trips) | `/Users/rich/burnwatch/assets/sounds/burn-default.wav` | 3.95 s, 24-bit WAV |
| Limit reset (a pool clears EARLY) | `/Users/rich/burnwatch/assets/sounds/reset-default.mp3` | 18.31 s, 256 kbps |
| Banked reset added (OpenAI bank count goes up) | `/Users/rich/burnwatch/assets/sounds/banked-default.mp3` | 7.68 s, 128 kbps |

Other copies of the same audio:

- Tauri build (byte-identical): `/Users/rich/imburning-tauri/ui/assets/sounds/{reset-default.mp3, burn-default.wav, banked-default.mp3}`
- Original uncompressed banked source (2 MB WAV; the mp3 is a 128 kbps encode Rich authorized):
  `/Users/rich/Documents/Codex/2026-08-24/files-mentioned-by-the-user-imburning/outputs/imburning_banked_clean.wav`

Rich's rules for this audio: ship it **byte-identical — never trim, normalise, or
re-encode** (the banked mp3 encode was a one-time authorized exception). The
18-second choir length is deliberate ("resets are a glorious event"). Do not
synthesise replacement audio.

## Trigger 1 — limit reset (`reset` sound)

Fires when a pool **clears early**: between two consecutive refreshes its
utilization falls from full-ish to empty **while the provider's promised reset
time is still in the future** (so scheduled rollovers stay silent — the promised
time has passed by the time the pool reads 0).

Exact rule, checked per pool on every refresh:

```
prev.pct >= 5            (EARLY_RESET_FROM)
curr.pct <= 1            (EARLY_RESET_TO)
prev.resets_at > now     (the promised reset had NOT arrived yet)
```

Pools watched: Anthropic five_hour + seven_day (+ extra rows), every
`codex.limits[]` / `codex.cli.limits[]`, every `gemini.limits[]` /
`gemini.cli.limits[]` — each keyed independently (`codex_<key>`, etc.).

State: a `prev` snapshot per pool key, **seeded on first load without firing**
(`_resetWatch === null` → take baseline, return). One sound per refresh even if
several pools cleared.

## Trigger 2 — banked reset added (`banked` sound)

OpenAI's banked limit-reset count comes from
`data.codex.resetCredits.available` (source: `chatgpt.com/backend-api/wham/usage`
→ `rate_limit_reset_credits.available_count`; MMT already reads this endpoint).

```
banked = prevBank != null && bank > prevBank
```

Also seeded silently on first load. **Priority rule:** if a banked reset and an
early clear land on the same refresh, play only the banked sound — it's the
rarer, more notable event.

## Trigger 3 — burning tokens quickly (`burn` sound)

Two layers:

**(a) The anomaly detector** (main process, runs after each refresh's history
append) decides which series are "burning". Per series (session, weekly, codex,
gemini, their CLI-account twins, and each Anthropic scoped pool):

- Jump = newest sample minus oldest sample within a **10-minute window**
  (`BURN_WINDOW_MS`); need ≥ **4 min** of span (`BURN_MIN_WINDOW_MS`) and
  jump ≥ **3 pct points** (`BURN_MIN_JUMP`) to even consider.
- Adaptive threshold once ≥ 50 baseline pair-rates exist: per-minute rates from
  consecutive sample pairs *older* than the window (pairs further apart than the
  refresh interval + slack are discarded; negative deltas = window reset,
  discarded). Anomaly when
  `jumpRate > median + 6 * MAD` (`BURN_MAD_K = 6`, MAD scaled ×1.4826,
  floored at 0.01).
- Cold-start fallback with < 50 baseline rates: anomaly when
  `jump >= 8` pct points (`BURN_FALLBACK_JUMP`).
- A tripped series stays "burning" for **45 min** (`BURN_SETTLE_MS`), with
  hysteresis: once its pace drops below half the trigger threshold it cools in
  **8 min** (`BURN_COOLING_MS`) rather than snapping off. (Notifications are
  separately throttled to one per series per 30 min — `BURN_COOLDOWN_MS` — but
  the *sound* keys off the burning STATE, not the notification.)

**(b) The sound edge-trigger** (renderer): keep the previous set of burning
series keys; on each refresh, if any key is burning now that wasn't burning
before → play the burn sound once (`break` after the first new key). Seeded on
first load without firing, same as the others.

```
if seeded:
    for k in burningNow:
        if k not in burningBefore: play('burn'); break
burningBefore = burningNow; seeded = true
```

## Playback details worth copying

- Per-sound settings: `{enabled: true, path: null, volume: 0.85}` — `path:null`
  means the bundled default; users can point at their own file and set volume
  (0–1). Each sound is independently toggleable.
- A re-trigger stops the still-playing previous instance of that sound first
  (keep a handle per kind), so overlapping events retrigger cleanly.
- Every trigger has a **seed-on-first-observation guard** — none of the three
  can fire on the app's first data load. This matters: a fresh launch always
  "sees" every pool/bank/burning-state as new.
- In MMT (native Swift) the natural equivalent is `AVAudioPlayer` per sound with
  `player.volume`; no CSP/data-URL machinery needed (that part is
  Electron-specific).

## Settings UI parity (optional)

I'm Burning! exposes per-sound rows in Settings: enable checkbox, current file
name (default label when `path` is null), a "choose file" button, volume
slider, and a test button that plays with `force` (ignores the enabled flag).
