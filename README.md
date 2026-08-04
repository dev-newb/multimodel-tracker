# Multimodel Tracker

A native macOS menu-bar app for watching usage limits across **several
subscriptions per vendor** — up to **4 accounts each** for Anthropic, OpenAI
and Google.

Existing trackers assume one login per provider. People who buy multiple
subscriptions can't see them together; that's the gap this fills.

## Status

Early scaffold. Builds and runs; the UI and data model are real, two of the
three provider adapters still need their auth flows.

| Piece | State |
|---|---|
| Menu-bar app + popover UI | working |
| Account model, 4-per-vendor cap, persistence | working |
| Staggered concurrent refresh | working |
| OpenAI adapter | fetch + parser written, needs the sign-in flow |
| Anthropic adapter | isolated web sessions written, needs the sign-in flow |
| Google adapter | not started — see "Open question" |

```bash
swift build
./.build/debug/MultimodelTracker            # menu bar
./.build/debug/MultimodelTracker --preview  # popover in a normal window
```

## Why the providers need different machinery

**OpenAI — plain HTTPS.** `GET chatgpt.com/backend-api/wham/usage` with a
bearer token and `chatgpt-account-id`. Verified against the live endpoint.
Multiple accounts is just multiple token pairs.

**Anthropic — needs a browser engine.** claude.ai sits behind Cloudflare,
which rejects plain HTTP client fingerprints, and auth is cookie/session
rather than a bearer token. **WebKit passes**: a `WKWebView` with an empty
cookie jar reaches the real API and gets Anthropic's own
`account_session_invalid` JSON back, not a challenge page. That single fact
is what makes a native app viable at all.

Multiple accounts therefore means multiple *isolated cookie jars* — one
`WKWebsiteDataStore(forIdentifier:)` per account (`WebSessionPool`). A shared
jar is exactly what limits other tools to one Claude login.

**Google — open question.** OAuth over plain HTTPS, but there is no public
OAuth client. Tools in this space borrow gemini-cli's, extracted from its
bundle — and gemini-cli is on a deprecation path while Antigravity, its
successor, ships no extractable client and keeps credentials in the system
keyring instead of a file. Needs a decision before implementing.

## Design notes

- **Tokens live in the Keychain**, one item per account id. `UserDefaults`
  holds only labels and cached percentages.
- **Refresh is staggered** (250ms per account). Twelve accounts hitting three
  vendors simultaneously is what gets a client rate-limited.
- The menu-bar badge shows the **worst pool per provider**, coloured amber
  past 75% and red past 90%, so the numbers are readable without opening
  anything.

## Layout

```
Models/     Domain.swift      Provider, Account, UsageLimit
            Store.swift       account CRUD, staggered refresh, persistence
Providers/  Adapter.swift     UsageAdapter protocol + registry
            OpenAIParser      wham/usage -> UsageLimit
            WebSessionPool    per-account WKWebView + Anthropic parser
Support/    Support.swift     Keychain wrapper, shared UA
UI/         App.swift         NSStatusItem, badges, popover, --preview
            PopoverView       provider -> account -> pools
```
