# Model usage and account attribution

## Detail controls

The bottom chevron on each account card opens/closes model details vertically using the Config panel's 0.12-second ease-out timing. The arrow retains its original 16-point row and plain styling. The outer list and non-Google detail scroll containers use `.scrollIndicators(.never)` to hide their indicators even when a mouse is attached, including during expansion/contraction; wheel and trackpad scrolling remain enabled. Non-Google details scroll within a 240-point viewport, keeping the collapse control outside that scroll area; the outer list reveals the control after expansion if necessary. Reduced Motion disables the transition. Details refresh every minute while expanded; collapsing retains the loaded report. Background refresh does not insert/remove controls around the arrow. Historical usage bars compare model amounts within the selected report. Native quota bars use a fixed 0–100% scale and say “quota used.”

Config → Layout → **Show model details** hides the entire detail section and its bottom chevron for every account. It is on by default and persisted. Account roll-up controls and the main quota bars remain available. Replacing a login recreates its detail view so a response from the previous identity cannot populate the new one.

## OpenAI

Read the authenticated `GET /backend-api/wham/usage/daily-token-usage-breakdown` with that row's bearer token and ChatGPT account header. Request 30 UTC dates and aggregate `data[].attribution[].value`, falling back to `data[].models[].credits` only when a day has no attribution, preserving the response's declared units. Recent seven-day responses were empty while the 30-day response returned older activity. The UI shows the OpenAI server source, spelled-out units and latest reported activity date above the model bars; no current usage is invented from older values. Consumer responses tested on this Mac report `percent`; daily percentages are summed as percentage points (pp), not tokens, money, or remaining allowance. The response does not establish a token conversion or complete cross-device coverage. Do not add `models[].credits` to attribution: these are overlapping representations.

The authenticated endpoint returns per-model data. Backend billing behavior when the same conversation is continued under two accounts has not been independently verified. The UI says so. Local Codex logs are not a substitute: the inspected token events have no payer identity.

Imported CLI credentials are no longer silently replaced from the CLI's current login when the old token expires/disappears. Use Reconnect for an expired tracked account. A repeated import of an already tracked email is rejected rather than adding another row, and switching the CLI cannot relabel another account's card.

Sources:
- https://github.com/openai/codex/blob/main/codex-rs/backend-client/src/client/analytics.rs
- https://github.com/openai/codex/issues/16323

## Claude Code

Removed before merge. A local OTLP/HTTP collector for Claude Code was built here as a route to seeing Anthropic's banked (never-granted) reset. It cannot: telemetry carries tokens *spent*, never reset offers or entitlements, and no live Claude Code event was ever received. The offer is a web-surface entitlement (`ineligible_reason: "surface"` on OAuth); the tracker already holds a headless claude.ai session for legacy rows, which is the elegant path once the endpoint is known.

## Claude saved resets

Removed the provisional reset probes, embedded Claude Usage window, web connection controls, and web reset session reads at the user's request. The OAuth offer was surface-restricted; no reliable native inventory was established. No reset was redeemed. Existing hidden legacy sign-in support remains for quota fetching.

## Anthropic native quotas

Subscription limits, including Weekly — Fable, appear on the main account card. Anthropic cards carry no model-details disclosure: there is no account-scoped model breakdown to fetch.

## Google Antigravity

Verified the installed local database schema and protobuf descriptors embedded in `/Applications/Antigravity.app/Contents/Resources/bin/language_server`. `gen_metadata` has model/token data; `trajectory_meta` has conversation IDs, source and type. `CortexStepMetadata`, `CortexTrajectoryMetadata`, `ChatModelMetadata`, `ChatStartMetadata` and `ModelUsageStats` do not expose a per-request account identity. The 36 bounded generation records inspected had custom keys for execution, step, model and trajectory information; response headers only included `sessionID`. None establishes which account paid for a request after switching accounts.

The Google detail panel now reads amounts from `retrieveUserQuota` with the selected account's credentials and resolved project; `fetchAvailableModels` supplies display names only. A catalog can describe 100% model availability without measuring usage. Missing, disabled and invalid amounts are excluded, and a response without measurable quota buckets produces an error. Machine credentials are used only for an explicitly imported machine account. These are current quota percentages, not historical token totals; shared pools are called out. The main card uses `retrieveUserQuotaSummary` and accepts flat or nested remaining-fraction fields. It no longer substitutes catalog availability or a cached last-good report when a fresh quota request fails. This finding covers the installed schema and inspected records; it is not a claim that Google has no internal accounting data.

## Verification

Run `bash Tests/run-usage-tests.sh` (uses the real parsers and ledger; no Xcode/XCTest required), then `swift build --disable-sandbox -c release`. Render the collapsed/expanded design with `MultimodelTracker --render-details /absolute/path/preview.png`.

For a read-only live detail check, launch the installed bundle with `--detail-diagnostics /absolute/path/report.json`. It uses the same native detail service as the UI, after main refresh, and keeps that same process running. The report omits credentials and account identifiers.

Live native service verification on September 23 returned 23 Google model quota rows, five OpenAI model totals (latest activity September 15), and the Anthropic scoped Fable limit at 100% before the duplicate detail section was removed. Claude Code event count remained zero. A fresh, uncached OpenAI server request at 11:42 UTC on September 23 still returned percent units and zero model values for September 16–23. This is a limitation of the returned account history, not a local Codex log-reading dependency. Other-device reporting and account-switch billing have not been established by that response.

## Popover geometry regression

Both scroll viewports use measured document heights with explicit caps. `NSHostingController` automatic preferred-size updates are disabled; bounded geometry updates resize the popover relative to its status item. The fallback panel preserves its top edge and horizontal centre. Neither path uses `fittingSize` (which is zero with automatic hosting sizing disabled).

Run `.build/release/MultimodelTracker --test-popover-layout` after building. The native fixture posts 21 mouse presses to its own window, including the left edge of the arrow's full-width target, changes 23 models to 100, checks bounded height and menu anchor coordinates, and checks fallback panel growth/shrink. No Store, network requests or Keychain reads are initialized by this mode.

### Menu-bar window regression found in full-app validation

The earlier ordinary-window fixture did not cover the real menu-bar window. On the affected setup, `NSStatusBarWindow.screen` was nil and its frame was above the current display bounds. AppKit placed the popover at x=0 despite the status item being at x=2822. The corrected path selects the display from the item's frame (or nearest display for a stale frame), pins the window to that item, and does not re-show it during content resizing. Reopening a visible tracker retains its window and disclosure state. The unrequested increase in arrow spacing was reverted.

Use an isolated app identifier with `--mock --mock-three --open --layout-trace /absolute/path/layout.jsonl` for full UI checks. Mock model details make no credential or provider requests. The opt-in trace records only this app's window geometry, screen frames and timing. Validate normal UI actions through the native computer-use tool; the narrow self-test alone is insufficient evidence for menu-bar placement.

September 23 cleanup: native UI checks confirmed the installed Anthropic detail panel no longer repeats Weekly — Fable. An isolated full-app 23-model fixture verified expansion, scrolling to the bottom, and contraction with no scrollbar; `.hidden` was insufficient with a mouse attached, so the final build uses `.never`. The fixture retained its menu-bar anchor. After the final restart, the installed app reported Keychain user-canceled errors (-128) for Anthropic and OpenAI, so live UI refresh remains blocked; the read-only server check used the current Codex login, whose email matched the visible tracker account.

## Sign-in recovery and model history freshness

Google's signed-out card now exposes the existing browser Sign in flow. Successful browser sign-in removes that row's machine-import marker and clears its cached Google project so the newly stored credential is actually used. Previously the card excluded Google and an imported row would keep ignoring its new browser credential.

OpenAI model reads explicitly bypass the local response cache and request server revalidation. The expanded section places Refresh details and its successful check time at the top, separately from the latest nonzero activity date. A main-card refresh also triggers expanded details to refresh. Model totals are labeled as history; an old activity date receives an explicit notice before the bars. Records outside the requested 30 UTC dates, including future records, are excluded.

Further live investigation on September 23 at 15:43 UTC, using the account matching the OpenAI card:

- Daily model history returned HTTP 200, percent units, and empty attribution/model arrays for September 21–23 (also tested an end date of September 24 to rule out a date boundary issue).
- The live usage endpoint returned the current 11% weekly quota. Its model_usage field contains availability booleans, not model consumption.
- The workspace token-history endpoint returned HTTP 400 for this consumer Pro account.
- The newer plan_limit_history endpoint returned HTTP 200 with data_as_of September 23, coverage_complete=false, and accounting_complete=false. Its only returned weekly period ended September 19; it cannot provide this week's model usage.
- The profiles/me report returned stats_as_of September 23 and account-wide token counters, but no model breakdown. It cannot fill in missing model totals.

The requests match the upstream Codex analytics contracts. These findings establish a gap between the provider's live quota and its model history, not complete coverage of all devices or account-switch billing. The tracker does not fill the gap using unattributed local logs or invent token/model amounts. Today's missing per-model totals remain unresolved upstream.

Sources: OpenAI Codex backend-client client/analytics.rs, client/plan_history.rs, client/profile.rs, and tui/src/analytics/normalize.rs at https://github.com/openai/codex/tree/main/codex-rs .

The exact OpenAIModelUsage.fetch implementation was compiled with transport stubs and run against the current Codex login at 16:00:49 UTC on September 23. The request succeeded with five model rows and latest activity September 15, confirming that the production fetch/parser also receives the old history. This diagnostic used no Keychain helper and printed no credentials. Native installed UI verification confirms Google Sign in is present; browser sign-in completion remains unverified.

## Account replacement and resize corrections

A browser sign-in replaces the identity and usage in the existing slot while preserving its nickname. An in-memory credential revision scopes Google project, tier and email caches; late quota responses from the old revision are discarded. Google userinfo supplies the email when OAuth omits the ID token. The token exchange form preserves literal plus signs and other encoded characters. A missing quota project is an error rather than a projectless request. Requests bypass the response cache and have a 20-second timeout.

Run `bash Tests/run-account-tests.sh` for login replacement, stale response isolation, nickname preservation and persistence compatibility. `bash Tests/run-usage-tests.sh` includes a regression in which model availability says 100% remaining but the quota bucket says 25%; the displayed amount must be 75% used.

Window resizing now interpolates intermediate heights during account and model disclosure animations, with the top edge and horizontal position pinned. Previously the geometry callback resized the window to the destination before SwiftUI began animating the card. Native installed-app traces verified intermediate heights with constant x/top coordinates in both directions. The original 16-point model arrow row is unchanged. Stale badges and collapsed percentages are fixed to one line; names truncate first. Native screenshots of an isolated `--mock --mock-stale` bundle verified both grid and rolled-up cards without reading any credentials.

### September 23 endpoint investigation

- Current Google CLI documentation says `/usage` (alias `/quota`) refreshes quota/model configuration from the backend: https://antigravity.google/docs/cli/commands/usage/
- Current CodexBar implementation documents the distinction between quota and model availability, account matching for local sources, and the remote `loadCodeAssist`, `retrieveUserQuotaSummary`, `retrieveUserQuota` and `fetchAvailableModels` routes: https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md
- The locally running Antigravity app exposes an authenticated loopback `LanguageServerService/RetrieveUserQuotaSummary` with `forceRefresh: true`. A fresh read at 2026-09-24 01:59 UTC (September 23 locally) returned all four Gemini/Claude-GPT weekly/five-hour pools at 100% remaining. The identity was verified against the card at the time. This establishes what that source returned, not that work on every other account/device is correctly reflected.
- The running Antigravity build selected `daily-cloudcode-pa.googleapis.com`; the tracker's normal account-scoped OAuth route uses `cloudcode-pa.googleapis.com`. The opt-in `--google-diagnostics /absolute/path/report.json` compares these two explicit Google hosts, resolving each one's project separately. It exports only model names, percentages, public schema fields, timestamps and identity-match booleans; no credentials, emails, project identifiers or full responses.
- After Keychain approval, the installed tracker displayed OpenAI model activity through September 23 and weekly quota at 30%. The earlier daily-history gap had therefore recovered by that check. The implementation still uses the account-scoped daily history endpoint; the separate research query using this task's ID has not been substituted into the tracker.

The final rebuilt app was installed and signature-verified. Its fresh production/daily comparison was still waiting on macOS Keychain access at the end of this implementation pass; no live comparison result is claimed. Code and native layout verification passed independently.

### Follow-up: transient roll-up jitter

The previous trace deferred native move/resize notifications into a Task, so it observed only the final corrected frame. Synchronous notification capture reproduced a 2,196-point sideways excursion and an 81-point top-edge excursion during an ordinary header roll-up: setting `NSPopover.contentSize` made AppKit re-anchor to the wrong display edge on every frame, before `pin()` moved it back.

Shown popovers now resize their existing window with one combined frame change, preserving the chrome insets and top/center position while clamping to the display. `NSPopover.contentSize` is set only while hidden. The last requested content size is retained for reopening. The smooth height interpolation remains; header and model-arrow targets are unchanged.

Native computer-use checks covered four Anthropic/Google header transitions, closing/reopening through Config, two floating-panel transitions, and two transitions in the final installed app. Every synchronous frame event in those roll-ups kept x/top fixed and height moved monotonically. The same checker fails on the old trace's 2,196-point excursion.

For repeatable manual UI verification, use an isolated bundle identifier and `--mock --mock-five --open --layout-trace /absolute/path/trace.jsonl`, operate the header chevrons with the native UI tool, then run `python3 Tests/check-layout-trace.py /absolute/path/trace.jsonl`. Use `--kind panel` for the floating-window path. The fixture uses fabricated accounts and does not read credentials. This trace check supplements the older end-state self-test, which cannot detect a brief move corrected within the same run-loop turn.


## September 27: identities, controls and Google endpoint audit

### Endpoint findings

A live, account-scoped comparison through the installed app succeeded on September 27. Both Google rows verified the same identity. Production returned all four summary windows at 0% used, whereas the daily service returned nonzero Gemini weekly and five-hour use. Claude/GPT remained at 0%. The installed Antigravity language server was configured with the daily endpoint. These are observations from that check, not permanent expected values.

Normal Antigravity requests now follow the running installed client's `--cloud_code_endpoint`. Only the two exact HTTPS Google hosts are accepted. The last observed host is retained while Antigravity is closed; a new installation without a detected host defaults to production. Ambiguous multiple clients do not select a host by guessing which usage looks larger. Project/tier caches are invalidated on a routing change. Code Assist legacy mode continues to use production. The account's own OAuth credentials and project are used on the selected host; local Antigravity usage is not copied onto other accounts.

The remote quota service returned 27 bucket IDs: four editor-internal buckets and 23 model-related buckets. The catalog reused display names, including Flash Lite and Pro, for different IDs and older variants. The installed app's model configuration exposed 14 selectable variants. Therefore, a raw model-row count is not a count of independent subscription allowances. Exact repeated model/token-type buckets are deduplicated; distinct IDs with equal display names remain identified by their ID caption. Explicit disabled/hidden rows are omitted. Equal percentages alone never establish identity.

Google's official [model list](https://antigravity.google/docs/models/) and [CLI usage documentation](https://antigravity.google/docs/cli/commands/usage/) describe current models and refreshed backend quotas. The reference [CodexBar implementation](https://github.com/steipete/CodexBar/blob/main/docs/antigravity.md) also distinguishes declared shared pools from individual model observations.

### Native presentation

- Google details provide **Quota pools** and **Models** modes. Pools use `retrieveUserQuotaSummary` groups and windows; model amounts use `retrieveUserQuota`, with names from `fetchAvailableModels`. Catalog availability is never used as consumed quota.
- Google details have no inner scroll view. Model pages hold three rows; pool pages hold a named group (paging further if a future group contains more windows). Window height stays constant when changing pages.
- Every account, including a single Codex account and accounts in grid/pager/tab layouts, supports roll-up. The roll-up control precedes the rightmost remove control. Original header/model-disclosure geometry is retained.
- Vendor pager arrows use 26-point native targets and 12-point symbols; dots are 6.5 points. Left and right mouse clicks invoke the same navigation action.
- Nicknames remain. Source badges are visible for browser, CLI, Antigravity and legacy web credentials. Grid cards place the source beneath the compact header to preserve room for the nickname.
- Config has a centered add control beneath each company. Empty rows have a larger flat company-colored Sign in button immediately after the accent rail. Signed-in rows omit that button; failed authentication exposes Reconnect.

### Account identity and expiry

Identity is provider plus trimmed, case-insensitive email. Sign-in validates the email before replacing credentials. Import and refresh paths reject duplicate identities with “This [company name] account is already tracked”. Existing duplicates consolidate globally on load, preferring account-specific Google credentials over a machine login and otherwise the freshest record. Nicknames are preserved. Retired metadata and credentials are retained for recovery, while retired IDs are excluded from automatic account recovery.

Only non-secret authentication metadata is persisted. All new persisted properties are optional so old account records decode without loss. Email tooltips distinguish access-token expiry from the unknown lifetime of a renewable login. Imported Claude/Codex tokens cannot renew in the tracker; browser OAuth and Google refresh tokens can. Failed renewal requires Reconnect. Changing a machine Google login cannot silently assign the new user's usage to the old card, including when refreshing details directly.

### Verification

Account replacement/legacy persistence/identity/expiry/endpoint allowlist tests, usage attribution and Google grouping tests, and credential-read gate tests passed without live Keychain access. A native isolated fixture verified single-account Codex roll-up/reopen, both Google views, left/right-click detail paging, and the colored Sign in row. Four synchronous popover transitions kept x/top fixed (`Tests/check-layout-trace.py`).

Testing also exposed an existing empty-account deletion crash in WebKit's static data-store removal API. OAuth-only/empty rows now skip WebKit cleanup. Existing legacy stores clear their data through an initialized view retained until completion. Mock deletion never touches credentials or cookie stores.

The Mac locked during the remaining UI checks. Repeated vendor-pager interaction and the final installed UI still require visual verification after unlock; the successful fixture checks above are not presented as those checks.


The final bundle was signature-verified, installed, and launched. Persisted account counts changed from 2 Anthropic / 1 OpenAI / 2 Google to 2 / 1 / 1; the retired duplicate's metadata was preserved. The installed application selected the daily Google service. Its post-install authenticated refresh was still pending while the Mac was locked, so the earlier live comparison—not post-install usage—is the evidence for the endpoint mismatch.

## Google service: production or daily

Antigravity can run its language server against Google's daily service (`--cloud_code_endpoint https://daily-cloudcode-pa.googleapis.com`), and the two services report different quota balances. The tracker follows whichever the installed client is using, read from the language server's arguments through `sysctl` (the choice exists nowhere on disk). Config > Google > Service shows what it is following and lets you pin production or daily; the Google card wears a small `daily` tag while that is the source. With Antigravity not running, the last host seen live is used.
