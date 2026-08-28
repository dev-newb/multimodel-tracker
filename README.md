# Multimodel Tracker

A native macOS menu-bar app for watching usage limits across **several
subscriptions per vendor** — up to **4 accounts each** for Anthropic, OpenAI
and Google, side by side.

Existing trackers assume one login per provider. People who buy multiple
subscriptions can't see them together; that's the gap this fills.

The menu bar shows one compact badge per provider (`A25 O100 G0`) carrying
that vendor's *worst* pool — amber past 75%, red past 90% — so the numbers
are readable without opening anything. Click it for the full breakdown:
provider → account → pools, each pool with its percentage, bar and reset
time.

## Install / build

Requires macOS 14+ and Xcode command-line tools.

```bash
git clone https://github.com/dev-newb/multimodel-tracker.git
cd multimodel-tracker
./make-app.sh
open "build/Multimodel Tracker.app"
```

`make-app.sh` builds with SwiftPM and signs with your Developer ID or Apple
Development certificate when one exists (selected by SHA-1 hash, never by
name — duplicate cert names are common and abort by-name selection). With no
certificate it falls back to ad-hoc signing, which works but re-prompts for
keychain access after every rebuild.

## Signing in

- **Anthropic** — per-account OAuth in your real browser (the same
  "log in with your Claude account" flow Claude Code runs). If you're already
  signed in to claude.ai there, it's a single Authorize click; the app keeps a
  refresh token per account, so four accounts stay signed in simultaneously.
  Accounts from the old embedded-window flow keep working through their
  isolated cookie jars.
- **OpenAI** — either one-click **Import Codex CLI** (adopts `~/.codex/auth.json`)
  or per-account OAuth in your real browser (Codex CLI's flow). Legacy
  web-window accounts re-mint expired tokens silently from surviving cookies.
- **Google** — **Import Antigravity / gemini-cli**: the login already on your
  Mac *is* the credential. Quota comes from the Code Assist
  `retrieveUserQuota` endpoint, one bucket per Gemini model.

## Bar effects

Pools that are fully burned or burning fast get animated bars.

- **Dead (100%)**: flatline, glitch, bleed, dead channel, black hole, drown,
  petrify, neon burnout.
- **Burning** (usage climbing unusually fast): firestorm, coal bed,
  blowtorch, comet, fuse.

Burn detection is adaptive, ported from
[I'm Burning!](https://github.com/dev-newb/imburning): the jump is measured
over a 10-minute window against the pool's own historical rate
(median + 6·MAD), with an absolute 3-point floor, an 8-point fallback until
enough baseline exists, and a 45-minute afterglow with hysteresis so a pause
between prompts doesn't snuff the flames.

The Accounts window (▸ Accounts… in the popover) picks the animations: pin
one per category, cycle every 3rd view, or let every affected bar differ at
once.

## Why the providers need different machinery

**OpenAI — plain HTTPS.** `GET chatgpt.com/backend-api/wham/usage` with a
bearer token and `chatgpt-account-id`. Multiple accounts is just multiple
token pairs, stored per-account in the Keychain.

**Anthropic — OAuth first, browser engine for legacy.** Accounts signed in
through the browser hold an `api.anthropic.com` bearer token; that host's
usage endpoint answers a plain HTTPS GET with the same `limits[]` payload as
claude.ai's own, so polling needs no browser engine at all. Accounts from
the old embedded-window flow still poll claude.ai, which sits behind
Cloudflare and rejects plain HTTP client fingerprints — WebKit passes the
check (presenting an honest WebKit user agent is required; claiming to be
Chrome from a WebKit engine puts login into an unsolvable challenge loop).
Those accounts keep their *isolated cookie jars* — one
`WKWebsiteDataStore(forIdentifier:)` each.

**Google — borrowed credentials.** There is no public OAuth client for Code
Assist quota. The app reads the refresh token Antigravity (or gemini-cli)
already stores on your Mac and redeems it with the OAuth client embedded in
Antigravity's own binaries — a refresh token can only be redeemed by the
client that issued it, which is why borrowing gemini-cli's client against
Antigravity's token can never work.

## Security model

- **Tokens live in the login Keychain**, one item per account. Claude
  sessions live in per-account WebKit data stores. `UserDefaults` holds only
  labels, cached percentages and usage history — never credentials.
- Keychain items are read **once per launch** and cached in memory, so polls
  never touch the keychain. macOS will ask once for Antigravity's item
  (it belongs to another app); *Always Allow* makes it permanent.
- Refresh is staggered (250 ms per account) so twelve accounts don't hit
  three vendors in the same instant.
- Nothing leaves your machine except the providers' own API calls.

## Debug flags

| Flag | What it does |
|---|---|
| `--preview` | popover content in a normal window |
| `--open` / `--accounts` | open the popover / Accounts panel on launch |
| `--render-maxed <dir>` / `--render-burn <dir>` | render every bar effect to PNGs, offscreen |
| `--burn-sim` | run the burn detector against synthetic histories (6 rules, PASS/FAIL) |
| `--recover` | rebuild the account list from surviving keychain items and cookie jars |
| `--bridge-test` | probe the claude.ai page bridge |
| `--cursor-probe` | walk the pointer down the Config panel, report live cursor vs the governor's decision |
| `--loopback-test` | exercise the OAuth redirect catcher without a browser |
| `MMT_DEBUG=1` | log refreshes and window metrics to stderr |

## Layout

```
Models/     Domain.swift      Provider, Account, UsageLimit
            Store.swift       account CRUD, refresh, burn detector, persistence
Providers/  Adapter.swift     UsageAdapter protocol + OpenAI/Anthropic adapters
            OpenAIParser      wham/usage → UsageLimit
            OpenAIOAuth       browser OAuth, Codex CLI's client
            AnthropicOAuth    browser OAuth, Claude Code's client
            OAuthLoopback     shared PKCE material + loopback redirect catcher
            GoogleAdapter     Antigravity/gemini-cli credentials + quota
            WebSessionPool    legacy per-account WKWebView + Anthropic parser
Support/    Support.swift     Keychain wrapper, Codex CLI import
UI/         App.swift         status item, badges, popover, cursor governor,
                              debug flags
            PopoverView       provider → account → pools
            AccountsView      accounts + bar-effect preferences
            MaxedBar          the eight dead-bar treatments
            BurningBar        the five burning treatments
```
