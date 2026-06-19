# SturtBar Brand, Voice and Design Guidelines

Version 1.854-draft. Australian English throughout. No em dashes, ever.

SturtBar is a macOS menu bar app that tracks AI plan usage: session windows, credit balances, and reset countdowns. It launches supporting one provider and is designed to expand to several. The brand never names, imitates, or implies affiliation with any provider. Providers are simply "stations" whose lights we keep.

---

## 1. Brand foundation

### 1.1 The story

Cape Willoughby, on the eastern tip of Kangaroo Island, was South Australia's first lighthouse. It was originally named the Sturt Light, first lit on 16 January 1852, and stood watch over Backstairs Passage, the narrow and treacherous strip of water between the island and the mainland, so that ships did not run aground. It was crewed around the clock by three keepers. It was the 17th lighthouse built in Australia, and in 1992 it became the last South Australian light to be demanned.

SturtBar is that light, re-manned by software.

### 1.2 The one-sentence brand

**The light that watches the passage so you don't run aground.**

Usage limits are the rocks. Your remaining quota is your sea room. SturtBar keeps the light burning so you always know how much passage you have left.

### 1.3 Brand the Light, not the man

Every piece of copy, art, and lore points at the lighthouse, the keeper, and the coast. None of it points at Charles Sturt the explorer. This is a hard rule. It keeps the brand warm and maritime rather than colonial and dusty, and it sidesteps the name's competing associations (the university, the footy club). If a sentence is about a person from the 1800s, cut it or rewrite it to be about the tower.

### 1.4 Personality in three words

Watchful. Dry. Unflappable.

The product has seen every kind of weather since 1852 and is not alarmed by your token burn. It informs; it never panics, nags, or moralises.

Watchful covers more than the water. The Keeper minds the keys as part of the watch: your credentials are read, never altered, and what the light sees is nobody else's business. It watches the passage, not the passenger.

---

## 2. The metaphor system

These mappings are canonical. Use them consistently in UI, copy, and code naming.

| Product concept | Brand concept |
|---|---|
| The menu bar item | The Lamp |
| The detail popover | The Logbook |
| A usage window (e.g. 5-hour session) | The Passage |
| Remaining quota | Sea room |
| Usage history view | Backstairs Passage |
| An alert / notification | A Notice to Mariners |
| Hitting a limit | Running aground |
| A reset | The tide turning / refloating |
| Being rate limited | The light is doused |
| An AI provider | A station (a light on the coast) |
| Adding a provider | Lighting a station |
| The app's mascot/voice | The Keeper |
| Your Claude Code credentials | The keys |
| SturtBar's own keychain cache | The key safe |
| The privacy posture | The Keeper's watch |
| The performance posture | The keeper's economy |

The last four are flavour only. They never replace plain language in an actual security or performance claim; see section 6.

### 2.1 Usage states

Four canonical states drive colour, glyph, and copy everywhere:

| State | Meaning | Threshold (default) |
|---|---|---|
| Clear passage | Plenty of sea room | 0 to 74% used |
| Shoaling | Approaching the limit | 75 to 94% used |
| Hard aground | At the limit | 95 to 100% used |
| Light doused | Rate limited / locked out | Provider lockout active |

### 2.2 Stations (multi-provider system)

Each provider is a historical South Australian light station, assigned in order of when SturtBar adds support:

1. **Willoughby** (the Sturt Light, 1852): the first provider supported at launch.
2. **Borda** (Cape Borda, 1858): the second provider.
3. **Troubridge** (Troubridge Island, 1855): the third.
4. **Northumberland** (Cape Northumberland, 1859): the fourth.

Station names are internal flavour and section labels only. The UI always shows the provider's real product name where the user needs to identify it; the station name may appear as a subtitle or in the Logbook, never in place of clarity.

---

## 3. Voice: the Keeper

### 3.1 Register

Laconic, faintly bureaucratic South Australian public servant, circa a well-run 1850s light station, writing in the present day. Dry wit, never sarcasm at the user's expense. Short declarative sentences. Understatement over exclamation. The model is the real Marine Board minute that praised the station's "good order, cleanliness, and discipline".

### 3.2 Rules

- Australian English spelling, always.
- No em dashes. Use commas, colons, parentheses, or a full stop.
- No exclamation marks except in genuine celebration, and rarely then.
- Numbers and times are exact and prominent. The Keeper is precise; the wit lives around the data, never instead of it.
- Never blame the user. Weather happens. "You've used your quota" not "You've burnt through your quota again".
- Never reference the explorer, colonisation, or any named historical person.
- Never name a provider's brand in flavour copy. Providers appear by name only in functional UI (account labels, settings, onboarding pickers).
- Theme density is inversely proportional to glance frequency. The menu bar shows almost no theme. The popover shows a little. Notifications show one line of it. The About box and onboarding can be soaked in it.
- When the subject is the user's credentials, keychain, or data, the Keeper drops the metaphor and states the fact plainly. Themed security lines are for marketing surfaces only; the claim itself is always literal (see section 6 and the hard boundaries).

### 3.3 Canonical microcopy

State lines (popover status):

- Clear passage: "Passage clear. On you go."
- Shoaling: "You're making leeway toward the rocks. {n}% sea room left."
- Hard aground: "Hard aground. Tide turns {time}."
- Light doused: "Light's doused. Nothing in or out until {time}."

Notices to Mariners (notifications, always prefixed `Notice to Mariners:`):

- 75% threshold: "Notice to Mariners: shoaling water ahead. 25% of the session remains."
- Limit reached: "Notice to Mariners: vessel aground. Refloat expected {time}."
- Reset: "Notice to Mariners: tide's turned. Full passage restored."
- Weekly limit nearing: "Notice to Mariners: the week's drawing in. {n}% remains until {day}."

System moments:

- First launch: "Cape Willoughby. First lit 1852. Standing watch over your tokens since you installed me. The Keeper watches the water, not you." (Forward-looking: there is no onboarding surface yet; today this voice lives in the launch log and the first keychain pre-prompt.)
- New station added: "{Provider} station lit. The coast gets safer."
- On quit: "Dousing the light. The Passage is on its own."
- Error, can't reach provider: "Fog's come in. Can't sight {provider} just now. Will keep watch."
- Empty state, no account connected: "No light on this coast yet. Connect an account and we'll get it lit."
- About box: "The 17th light raised on this coast, and the first in South Australia. Demanned 1992. Re-manned, reluctantly, by software."

Trust moments (the claims are literal; see section 6):

- Keychain pre-prompt (the macOS keychain dialog itself cannot be customised; this is the explainer alert shown first): "SturtBar will ask macOS Keychain for the Claude Code OAuth token so it can fetch your Claude usage. It reads the token; it never changes it. Click OK to continue."
- Auth error (popover status line, plain and actionable, always names the credential source): "Re-authenticate in Claude Code: {detail}"
- Keychain permission stuck (the action comes first; the menu card truncates long detail): "Open the SturtBar menu, press ⌘R, then allow Keychain access. Claude Code's sign-in changed and SturtBar can't read it yet."
- About box privacy line (themed surface, literal claim): "The Keeper watches the water, not you. No telemetry, no analytics; your keys stay in the keychain and are never altered."
- About box footer (literal, tiny): "No. 17 · MIT License · Zero third-party dependencies"

### 3.4 Voice don'ts, with corrections

| Don't write | Write |
|---|---|
| "Oops! You've hit your limit 😅" | "Hard aground. Tide turns 02:00." |
| "Warning!! 95% used!!" | "Notice to Mariners: shoaling water ahead." |
| "Charles Sturt would be proud" | (nothing; we don't do the man) |
| "Your Claude tokens are running low" | "Sea room's getting thin at Willoughby station." (flavour) or "{Provider}: 12% remaining." (functional) |
| "Don't worry, resets soon!" | "Refloat expected 02:00." |

---

## 4. Visual identity

### 4.1 Design principle

One warm light on warm neutrals. The entire visual system is a single warm accent (the lamp) glowing against warm paper and warm darkness. Calm, editorial, paper-like. Nothing cold, nothing neon, nothing sci-fi.

### 4.2 Palette

Core neutrals and accent:

| Token | Hex | Role |
|---|---|---|
| `lamp` | `#D97757` | THE accent. The lamp glow, the tower band, primary buttons, the brand's one warm light |
| `lamp-halo` | `#E9B49C` | Soft halo around the lamp, hover tints, subtle fills |
| `ink` | `#141413` | Warm near-black. Text in light mode, night field, glyph silhouette |
| `paper` | `#FAF9F5` | Warm ivory. Light mode background, tower stonework, text on dark |
| `parchment` | `#E8E6DC` | Light grey. Subtle surfaces, cards, dividers |
| `granite` | `#B0AEA5` | Mid grey. Secondary text, the tower base, disabled states |

Sparing supporting colours:

| Token | Hex | Role |
|---|---|---|
| `passage` | `#6A9BCC` | Muted blue. A sliver of sea in illustration only. Never a UI accent |
| `scrub` | `#788C5D` | Muted sage. Optional coastal scrub in illustration; may tint "clear passage" confirmations |

State colours (derived, used for fills and badges, never large fields):

| State | Light mode | Treatment |
|---|---|---|
| Clear passage | `granite` fill or `scrub` tick | Quiet. Good news whispers |
| Shoaling | `lamp` `#D97757` | The accent doing its actual job: warning warmly |
| Hard aground | `#A3402E` (deepened lamp) | Darker, hotter terracotta. Not a pure red |
| Light doused | `granite` at 50% | Everything dims. Absence, not alarm |

Rules: one accent per surface. If `lamp` is already on screen doing a job, nothing else gets colour. `passage` blue never exceeds roughly 5% of any composition. No pure black, no pure white, no cold blues or cyans, no gradients in UI (illustration may use soft radial glow on the lamp only).

### 4.3 Typography

| Role | Face | Notes |
|---|---|---|
| Wordmark, popover headings, About box | A warm serif: Tiempos, Newsreader, Source Serif, or Lora | The serif carries the brand's warmth and care |
| UI labels, body, settings | A clean humanist sans: system San Francisco is correct on macOS | Never fight the platform |
| Countdowns, percentages, balances | Sans with tabular numerals (SF Mono or SF Pro tabular figures) | Numbers must not jitter as they tick |

Sentence case everywhere, including headings and buttons. Title Case is forbidden, with one exemption: native macOS menu item titles follow platform convention (Title Case). Never fight the platform. The serif never appears in the menu bar.

### 4.4 The mark

The mark is the Cape Willoughby tower, simplified: a tapered circular tower (the real walls taper from 1.4 m to 0.86 m, keep a visible taper), a lamp room, one band in `lamp`, a low granite base. Day icon: tower on `paper`/manila field, soft `lamp-halo` glow. Night icon: tower on `ink` field, the lamp as the single warm point of light. Both ship; night is the default dock icon.

Icon construction rules: full-bleed background (the system masks the shape), no self-applied gloss, shadows, or borders (the OS material handles depth), bold simple geometry legible at 16 px, the band drops before legibility does.

### 4.5 The menu bar glyph (the Lamp)

The glyph is a monochrome template image (`isTemplate = true`); macOS handles light/dark inversion. Composition, left to right: the tower silhouette, then two vertical bars.

- **Tall bar**: the session window (e.g. the 5-hour passage). Outlined track, filled from the bottom as usage rises. The water climbing toward the rocks.
- **Short bar**: the long window (e.g. the weekly passage). Same treatment at roughly 60% height.

Height difference alone distinguishes them; no labels in the menu bar. A full bar is the message: tall bar full means the session is spent, short bar full means the week is. The tower is identity and alarm only, never a gauge.

Alarm treatment: on Hard aground (session), the entire glyph inverts into a filled rounded badge. Reserve inversion for the session limit only; the weekly limit announces itself by its own bar filling. On Light doused, the glyph renders at reduced opacity with the lamp pip hollow.

Technical: variable-length NSStatusItem, glyph slightly wider than tall, bar tracks at 2 px minimum stroke at 1x so non-Retina externals survive, hand-drawn image set or one base mark with bar fills drawn in code (SF Symbols cannot express the two custom bars). Optional user setting: numeric percentage text beside the glyph, off by default.

### 4.6 The popover (the Logbook)

Layout order, top to bottom: identity, numbers, time, lore.

1. **Header**: small tower mark, station/provider name, current state line in the Keeper's voice. Serif. The only themed text on the surface.
2. **The gauges**: the tower-and-tide treatment lives here, where it has room. The session renders as the tower filling from the base; the weekly window renders as a waterline rising across the scene. Large tabular numerals beside each: percentage remaining and the reset countdown.
3. **Credits/balance** (where a provider exposes it): a plain row, "Credits: $x.xx", no metaphor. Money is functional.
4. **Footer**: reset times in absolute and relative form ("Tide turns 02:00, in 3 h 12 m"), link to the Logbook history, settings gear.

Glanceability rule: the number the user came for is readable within 300 ms of the popover opening, top third of the surface, largest thing on screen. Lore never displaces data. If a themed element and a datum compete for space, the datum wins and the theme moves to the About box.

Multi-station layout: one section per station, separated by `parchment` hairlines, the same anatomy repeated. The menu bar glyph reflects the user's chosen primary station; others surface only in the Logbook and in Notices.

### 4.7 Motion

Almost none. Bar fills animate over 300 ms ease-out when the popover opens. The lamp pip may breathe very slowly (4 s cycle, opacity 85 to 100%) in the popover only, never in the menu bar. Countdown numerals tick without layout shift (tabular figures). No bounces, no confetti. When the tide turns, the bar drains in one calm motion and the state line changes. That is the celebration.

---

## 5. Notifications policy

Notices to Mariners are rare and useful, in keeping with a keeper who signals only when it matters. Defaults: one notice at 75% of a session, one at limit, one at refloat, one at 90% of the week. All individually toggleable. Never more than one notice per state transition. No marketing, tips, streaks, or re-engagement notices, ever. A lighthouse does not send push notifications asking if you've thought about it lately.

---

## 6. The standing orders: watch, guard, waste nothing

Protecting the user is part of the watch. The light exists so ships are not wrecked; the app exists so your privacy, your credentials, and your machine's resources are minded with the same discipline. Three standing orders cover it: watch the water (privacy), guard the keys (security), waste nothing (performance). This section is the canonical statement of that posture. Every claim in it is literal and stated in plain language, per the voice rules in 3.2.

### 6.1 The sanctioned tagline

**"The Keeper watches the water, not you."**

Marketing surfaces only (README, landing page, About box). It means exactly what it says: SturtBar watches your usage, never you. Wherever the tagline appears, the plain claims it fronts appear with it.

### 6.2 The posture

- SturtBar reads Claude Code's credentials read-only: `~/.claude/.credentials.json` first, then the `Claude Code-credentials` login keychain item. It never writes to either.
- If an expired token must be refreshed, the rotated token persists only to SturtBar's own keychain item, `com.michaelpalmes.sturtbar.cache` (the key safe). Claude Code's stores are never touched.
- Session logs under `~/.claude/projects` are scanned locally for spend estimates: the token counts only, never the prompts or replies. Nothing is uploaded.
- Codex is opt-in and inert until enabled. While the Codex provider is on, SturtBar reads its sign-in read-only from `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`): it never writes the file, never refreshes Codex tokens, never parses the identity token, and never calls `auth.openai.com`. The only filesystem touch before opt-in is a single existence check (stat) on that path while the Settings window is open, to drive the "codex CLI not detected" hint; it reads no contents.
- While the Codex provider and local cost tracking are both on, Codex session logs under `~/.codex` (`sessions` and `archived_sessions`, or `$CODEX_HOME`) are scanned locally for spend estimates: the token counts only, never the prompts or replies. Nothing is uploaded. SturtBar never writes anything under `~/.codex`.
- Disabling a provider stops all of its reads and requests and wipes its cached snapshot.
- Logs are redacted before they are written: emails, tokens, and bearer credentials are masked.
- No telemetry, no analytics, no accounts, no tracking of any kind.

### 6.3 Every signal sent ashore

The complete list of network destinations. Anything not on this list does not happen (hard boundary 8):

| Destination | What and when |
|---|---|
| `api.anthropic.com/api/oauth/usage` | Reads your usage numbers, authenticated with the OAuth token, on each refresh |
| `platform.claude.com/v1/oauth/token` | Refreshes the OAuth token, only when a stored token has expired |
| `chatgpt.com/backend-api/wham/usage` | Reads your Codex usage numbers, authenticated with the codex CLI's existing sign-in, on each refresh, only while the Codex provider is enabled |
| `models.dev/api.json` | Fetches the pricing catalogue, unauthenticated, at most about once a day, and only while local cost tracking is enabled |

Links that open in your browser (the provider consoles and status pages) are not app traffic and stay off this list.

### 6.4 Prompt policy

Keychain prompts appear on user action (opening the menu, pressing ⌘R), plus at most one prompt during the first launch after install. Routine background refreshes never prompt.

### 6.5 The keeper's economy

A well-run station wastes nothing. Performance is housekeeping, not heroics: the brand never brags about speed, it accounts for it.

- **Lean by construction.** Zero third-party dependencies, native Swift on system frameworks, menu bar only. Work runs on demand: cost scans when something asks, icon renders when the reading changes, nothing on the launch path that can wait.
- **Measured, not assumed.** The hot paths carry signposts (launch, refresh, scan, iconRender, menu), inspectable in Instruments under `com.michaelpalmes.sturtbar`, and CI fails any change that lets the cost scanner fall behind a naive baseline. A performance claim traces to one of these or it is not made.
- **Felt, then promised.** The 300 ms glanceability rule (4.6) is the standard the Logbook is held to. It is a target we design against, never a result we report.
- **Figures travel with their method.** Footprint numbers (bundle size, idle memory, scanner speedup) live in the README's Performance section, each with the command that produced it and the machine it ran on (hard boundary 9). This section states the standards; it never caches the numbers.

The sanctioned performance line, marketing surfaces only: **"Good order, cleanliness, and discipline."** The Marine Board's own words for the station (3.1), quoted exactly, never paraphrased, and always within reach of the plain claims they front.

### 6.6 Keeping the mirrors in sync

The README's Privacy and Performance sections and the landing page's printed plates (the notice of watch, 9.3, and the stores ledger, 9.4) are the public mirrors of this section. When the posture, the destination list, or a published figure changes, the mirrors change in the same commit.

---

## 7. Lore, easter eggs, and naming

All lore is true history, which is the house rule: never invent heritage.

- Version numbering begins at 1.852; build numbers may use 1852.
- A small "No. 17" mark may appear in the About box (17th light built in Australia).
- "First to shine, last to sleep" is the sanctioned tagline for the always-running monitor (first SA light lit, last SA light demanned).
- The usage history view is titled "Backstairs Passage".
- The origin beat, for the README and About box only: the light's namesake, as Colonial Secretary, raised the money from shipping interests to build the very light that warned their ships off the rocks. The funder paid for the warning. (Told without naming him, per 1.3.)

Reserved names: the Lamp, the Logbook, the Passage, Notices to Mariners, the Keeper, station names per 2.2.

---

## 8. Hard boundaries

1. **No provider affiliation.** Never use a provider's logo, wordmark, mascot, bespoke typeface, or unmistakable trade dress. The shared warmth of the palette is a mood, not a costume. If a reasonable person could mistake SturtBar for a first-party product, pull back.
2. **No provider names in flavour copy.** Functional UI only.
3. **No explorer content.** See 1.3.
4. **No cold tech aesthetics.** No cyan, no neon, no glassmorphism beyond what the OS applies, no circuit imagery, no robots.
5. **No guilt mechanics.** No streaks, no shame copy, no "you've been busy!". The Keeper reports the weather; the user sails as they please.
6. **No invented history.** Every date, number, and historical claim in the product must be real.
7. **Accuracy beats theme.** If a metaphor obscures what the number means, the metaphor loses.
8. **No silent calls.** Every network destination the app talks to is enumerated in 6.3, in the README, and on the landing page, with what is sent and when. A new destination ships with its disclosure in the same change, or it does not ship. We never invent heritage; we never hide where the signals go.
9. **No unmeasured numbers.** Performance figures ship with the measurement that produced them: the command, the machine, and the version. Design targets (the 300 ms glanceability rule) are stated as targets, never as results. If it was not measured, it is not claimed.

---

## 9. Landing page art direction: the archive

The marketing site uses an archival collage style: genuine 19th-century print ephemera presented as cut-outs and plates on warm paper, with a modern white serif doing the talking. The product's 1852 world supplies a real archive, which is what makes this honest rather than borrowed.

### 9.1 The collection

Source real, rights-cleared artefacts from SturtBar's own world only:

- Nautical charts: Flinders' 1802 charts of the South Australian coast; Admiralty charts of Backstairs Passage and Kangaroo Island.
- Engineering plates: lighthouse tower elevations and sections, lantern and lamp apparatus engravings, the Cape Willoughby site plan.
- Printed notices: the original Notices to Mariners announcing the light (December 1851), reproduced as scanned ephemera.
- Botany: Sturt's Desert Pea (Swainsona formosa) plates and SA coastal flora from 19th-century botanical works.

Sources: State Library of South Australia, Trove (NLA), National Archives lighthouse records, David Rumsey Map Collection, Biodiversity Heritage Library. Verify the rights statement on every individual item before it ships.

### 9.2 Treatment rules

- Every surface is a paper stock. Hero: terracotta chart-grid paper (a dusty terracotta near `#C8704F`, deliberately a step away from `lamp`). Content sections: `paper` ivory. Optional closing section: `ink` night with the lamp glowing.
- A faint square grid sits on the hero stock at very low contrast (it reads as chart graticule and logbook ruling). Add 2 to 3% fibre grain. Never let texture reduce text contrast below accessible levels.
- One or two collaged artefacts per viewport, rotated 3 to 8 degrees, soft 1 to 2 px paper-edge shadow, never overlapping type. Each artefact does one job beside the feature it illustrates.
- Artefacts are scans, not vector redraws. The age is the point.
- Product screenshots are mounted as folio plates: thin ivory mat, small italic caption beneath in the serif ("Pl. 1. The Lamp, shoaling"). Plate numbers may honour No. 17.
- Display type: the warm serif (Newsreader or Tiempos preferred at display sizes, Lora as fallback), white or ivory on terracotta, sentence case, generous negative space. Body copy in the serif on ivory; navigation, buttons, and download links in the quiet sans.
- The Keeper writes the page. Headlines are his lines ("First to shine, last to sleep"); functional copy stays plain.

### 9.3 The notice of watch

The privacy claims are typeset as one of the printed artefacts: a 19th-century notice in the style of the Notices to Mariners plates, set on its own paper stock beside the download links. Three printed rules:

- **What the light reads.** Claude Code's credentials, read-only; session logs, scanned locally. With the Codex provider enabled, its sign-in and session logs as well, read-only.
- **What signals it sends.** The destinations listed in 6.3, with their triggers.
- **What it never does.** No telemetry, no analytics, no accounts; never writes to Claude Code's stores or under `~/.codex`.

The headline may be the sanctioned tagline ("The Keeper watches the water, not you."). The list items are plain language and must match section 6 in substance. The artefact follows the same treatment and rights rules as the rest of this section. The genre makes plain disclosure feel native; it never decorates it into vagueness.

### 9.4 The stores ledger

The performance claims get the same treatment as the privacy claims: typeset as a printed plate, this time in the genre of a station's stores return. A light station ran on issued stores and the keeper accounted for them; the app accounts for the resources it uses.

- The artefact is product-owned and typeset, like the notice of watch: a small ruled ledger table carrying the README's published figures (bundle size, idle memory, scanner benchmark), each row with its method noted in the margin.
- It is captioned as ours ("The keeper's return, SturtBar {version}"), never aged, distressed, or passed off as a scan. The genre is borrowed honestly; the document is new and says so.
- If a genuine South Australian lighthouse stores ledger is ever sourced and rights-cleared, it may sit beside the typeset plate with its own provenance caption. It never carries the product's numbers.
- Figures match the README's Performance section in substance (6.6). A figure that has not been measured does not get a row (hard boundary 9).

### 9.5 Boundaries specific to the site

The archival-ephemera-on-warm-paper genre is a long-standing editorial style; the collection is what must be ours. Never reproduce artefacts, motifs, or compositions from any AI provider's own campaigns (no butterflies-on-grid, no borrowed plate scans). If an artefact is not from the South Australian maritime, botanical, or cartographic record, it does not belong on the page.

---

## 10. Quick reference card

- Brand in one line: the light that watches the passage so you don't run aground.
- Voice in one line: a dry, unflappable lightkeeper who has seen worse weather than your token burn.
- Palette in one line: one terracotta lamp (`#D97757`) on warm paper (`#FAF9F5`) and warm ink (`#141413`); blue is for the sea only.
- Type in one line: warm serif for the brand's voice, system sans for the data, tabular figures for anything that ticks.
- Layout in one line: data first, theme last; the menu bar is mute, the About box sings.
- Trust in one line: the Keeper watches the water, not you; claims in plain words, every destination disclosed.
- Performance in one line: the keeper's economy; lean by construction, measured before mentioned, every figure travels with its method.
- Landing page in one line: our own archive on warm paper; borrow the genre, never the collection.
