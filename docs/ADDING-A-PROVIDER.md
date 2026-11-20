# Adding a provider

A provider is one source of usage: a coding tool's subscription, or an API account. Adding one means adding **its own files and one line in the registry**, plus the README table row a test prints for you. If you find yourself editing a view, the store, the configuration or a shared helper, stop: the foundation is missing something, and that should be fixed once for everyone, not inside one provider.

- [1. Choose the kind](#1-choose-the-kind)
- [2. The rule about other tools' logins](#2-the-rule-about-other-tools-logins)
- [3. The interface](#3-the-interface)
- [4. Readings](#4-readings)
- [5. Errors](#5-errors)
- [6. Rules](#6-rules)
- [7. Files](#7-files)
- [8. Tests and previews](#8-tests-and-previews)
- [9. Checklist](#9-checklist)
- [10. Templates](#10-templates)
- [11. What the foundation doesn't do yet](#11-what-the-foundation-doesnt-do-yet)

## 1. Choose the kind

| Kind | Use it when | Files |
| --- | --- | --- |
| **Declarative definition** | One `GET` (HTTPS, or HTTP to localhost) with a pasted key in a header, answered with JSON where every number you need is at a fixed path or picked from an array by a field's value. Units and scale are fixed, at a path, or set per region. Optional: a success check on the body, a regional or user-entered base URL, a non-secret setting in the URL or a header, readings that are only sometimes present, a primary chosen by a value in the answer, a period taken from the answer. | `Providers/Declarative/<Name>Definition.swift` |
| **Swift provider** | Anything else: several requests, a two-step lookup (team id, then billing), sums across arrays or pages, a `POST`, a response whose shape decides what it means, another tool's sign-in or local files, a command. | `Providers/<Name>Provider.swift` |

Declarative definitions are the same JSON a user writes under `customProviders` in `config.json` (see the README's Configuration section), so they're also the best test of that format. Most balance endpoints fit, and these are built in as definitions: DeepSeek, Moonshot, Vercel AI Gateway, Novita, Hyperbolic, Ollama Cloud (both plan shapes), ElevenLabs, Poe, Venice, fal, Stability, AI/ML API, LiteLLM. Deepgram is Swift because its balances must be summed per unit. Spend that needs date maths or sums is Swift: OpenAI and Anthropic page through daily rows; Together answers in one page but its rows must be summed; Fireworks answers in one request with a total, but the request needs the start of the month. Inverted signs with a team lookup (xAI) and everything that reads another tool's login are Swift too.

`OpenRouterProvider.swift` is the reference Swift provider for "pasted key, balance in a currency". `ClaudeProvider.swift` is the reference for reading another tool's login.

## 2. The rule about other tools' logins

While researching providers, starting a tool's own CLI once to read its billing made that tool try to refresh an expired login; the refresh failed and the tool deleted its stored login, signing the user out. Other tools are known to start chat sessions or open sign-in pages in a browser when started. So:

- **Never refresh, rotate or write another tool's credential.** Read the token as stored, check its expiry locally (`StoredCredential` does both, including a JWT's `exp`), and if it is expired, missing or rejected, throw the typed error that says "open <tool> to sign in again". Never call a refresh endpoint, never start a login, never open a browser.
- **Prefer, in this order:**
  1. a local file the tool writes (a log line, a state file, a read-only SQLite query with `LocalTools.queryReadOnly`);
  2. a read-only HTTPS call with the tool's unexpired stored token, or a key the user pastes;
  3. starting the tool's own program, only when its documentation says that exact command is read-only and doesn't touch credentials or create sessions.
- **Starting a program is declared.** Put it in `descriptor.commands` as a `DeclaredCommand` with the exact arguments and a reason; `LocalTools` refuses anything else and runs it without a shell, in a temporary folder, with `BROWSER=/usr/bin/false`. Settings tells the user that turning the provider on runs it. A provider that starts a program can't be labelled `documented` unless `documentedReadOnly` is true, which you may set only when the tool's own documentation says so.
- **Codex is the one exception that's allowed today,** and it shows what that takes: Codex's app server can refresh Codex's login, so `CodexProvider` reads only the token's expiry first and doesn't start Codex when a refresh would be due. Don't copy it unless there is no other source.
- **Keychain prompts.** If reading another app's item can prompt (Electron "Safe Storage", another app's internet password), set `mayPrompt` on its `ToolStore`. When the user denies it, throw `.accessDenied`; the store then doesn't ask again until the user presses Refresh.
- **No borrowing.** Don't read a key one tool stored for another provider (OpenCode's store holds keys for many). If it is genuinely useful, offer it as an explicit setting (`SettingField` with `kind: .toggle`, off by default) and say so in `reads`.

## 3. The interface

```swift
protocol UsageProvider {
    var descriptor: ProviderDescriptor { get }
    func availability(in context: ProviderContext) -> ProviderAvailability   // cheap, local, no network
    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot  // throws ProviderError
}
```

The store adds the timeout (`descriptor.timeout`), cancellation and scheduling. Never sleep, retry in a loop or cache across fetches yourself.

`ProviderDescriptor` is everything the app shows without fetching:

| Field | What to put there |
| --- | --- |
| `id` | Stable lowercase id: `a-z`, `0-9`, `-`, starting with a letter. It names the provider in `config.json`, history and its Keychain item, so it never changes. Follow the account that is billed, not the editor brand. |
| `name`, `glyph`, `tint` | Display name, an SF Symbol (per-theme overrides in `glyph.themed`), a colour. |
| `category` | `.subscription` for a tool you run, `.api` for an account billed through an API. |
| `stability` | `.documented` (public API), `.undocumented` (what the provider's own tool uses), `.unverified` (from documentation, never checked against a real account). Be honest. It isn't shown to users; it records for maintainers how much a provider has been tested, and the contract tests use it. |
| `credential` | `.none`, `.toolStore(ToolStore)` (read-only access to another tool's store), or `.pastedKey(KeySpec)`. |
| `optionalKey` | A key the user may paste instead of the tool's sign-in. |
| `KeySpec` | `kind` (`.apiKey`, `.adminKey`, `.token` for an organisation- or workspace-scoped token, `.cookie`), `label`, a harmless `placeholder`, `helpURL`, and `warning` when the key can do more than read usage, with `advice` naming a narrower key if one exists. When none exists, `advice` says so plainly and says what to do instead: "There's no read-only key. Create one just for Dogwatch, with an expiry, and delete it when you stop using it." |
| `summary`, `reads`, `source` | One line for the list; exact sentences saying what is read and where it goes; a short source for the README table. |
| `allowedHosts` | The only hosts it may call. |
| `baseURLs`, `acceptsCustomBaseURL` | Regional endpoints (the first is the default), or any URL the user enters for a self-hosted gateway. |
| `fields` | Non-secret settings: team id, project id, account id, or toggles. |
| `localSources`, `commands` | Other files it reads; programs it starts. A `ToolStore` with `mayPrompt` (credential or local source) gets a Keychain-prompt warning in settings. Give a source or command behind a toggle `onlyWhen: "<field id>"`, and settings says "With “…” on, …" instead of "Turning this provider on …". |
| `minimumRefreshInterval`, `defaultRefreshInterval`, `timeout` | Never fetched more often than the minimum (rate limits); default every five minutes; one fetch may take this long. |
| `idleLabel` | The small label before any reading: "Open Claude Code", "Add an API key". |

`ProviderContext` is all a fetch may use:

| Member | |
| --- | --- |
| `http` | An `HTTPClient` that calls only the declared hosts, over HTTPS (HTTP only to localhost), with no cache, cookies or redirects. `get`, `getJSON` and `send(URLRequest)` for other methods; `response(for:)` also returns the response headers, read-only and lower-cased (`header("link")`), for `Link` paging. Non-2xx statuses become typed errors. |
| `key()` | The pasted key or cookie from the Keychain, or nil. Put it straight into a header. |
| `settings` | `baseURL` and `values` of your `fields` (`value(_:)`, `isOn(_:)`). |
| `local` | `LocalTools`: `fileExists`, `read`, `tail(of:maxBytes:)` for growing logs, `modificationDate`, `contents(of:)` to list a folder (newest first), `queryReadOnly` for SQLite (never locks or writes the tool's file, and still sees changes in its write-ahead log), `run(_:)` and `authorize(_:)` for declared commands, `findExecutable`, `home`, `environment`. |
| `now()` | The current time; use it instead of `Date()` so tests control it. |

## 4. Readings

A `ProviderSnapshot` carries a list of `Reading`s, plus an optional `plan`, `label`, `note`, `activity` (exact token counts) and three hints. Convert units once, in the provider; formatting is central.

```swift
// A quota window: a share used, resetting at a time. Most coding subscriptions.
Reading(id: "five_hour", name: "5h session",
        value: .window(QuotaWindow(usedPercent: 27, period: .duration(5 * 3_600), resetsAt: reset)),
        meterLabel: "5h")

// The same with absolute numbers, when the provider gives them.
Reading(id: "monthly", name: "Monthly credits",
        value: .window(QuotaWindow(usedPercent: 31, period: .named("monthly"), resetsAt: reset,
                                   used: Amount(value: 310, unit: .credits), limit: Amount(value: 1_000, unit: .credits))))

// A balance: money or credits left, out of a total when there is one, refilling when it resets.
Reading(id: "balance", name: "Balance",
        value: .balance(Balance(remaining: Amount(value: 110, unit: .currency("CNY")))))

// Spend: money used over a period, against a budget when there is one.
Reading(id: "spend_month", name: "This month",
        value: .spend(Spend(amount: Amount(value: 61.75, unit: .currency("USD")), period: "this month")),
        freshness: "Complete through yesterday")
```

- **Units.** `AmountUnit`: `.currency("USD")` (ISO code), `.credits`, `.tokens`, `.requests`, `.custom("points")`. Convert cents, 1/10,000 units, units + nanos and inverted signs in the provider, into whole units.
- **Amounts are compact by default.** The panel's numbers and notes follow the user's `amounts` setting, `compact` unless they choose `full`: "1.3k credits" for 1,312. When the exact number matters (a balance of a few thousand credits), write it yourself in `detail` or a `note` with `UsageFormatters.amount(_:style: .full)`.
- **Percentages are never guessed.** `remainingPercent` exists only for a window, a balance with a total, or spend with a budget, all from real numbers. Without a total, the panel shows the amount (`$12.40`) and the menu bar does too. A user can type a total for a reading the provider gives none for (`config.json` `limits`, or the provider's settings); that's how Copilot's unpublished allowance or an API budget becomes a percentage. For a window whose total the provider doesn't publish, use `QuotaWindow.unmetered(used:period:resetsAt:)`: it shows "312 credits used" until the user types a total. Never invent one.
- **Incomplete numbers stay amounts.** When you know a figure is partial (paging stopped early, a day missing), set `isIncomplete: true` on the reading: it is never turned into a percentage, even against a budget, and say why in `freshness` or `detail`.
- **Not a plan limit.** A real cap that isn't the plan's limit (Claude's extra-usage cap, a spend budget beside a subscription) gets `canHeadline: false`: it shows its own percentage, but is never picked as the primary by default and never stands in for the plan in the menu bar's lowest. The user can still pick it as primary.
- **Which reading is shown.** By default the primary is: the reading you name in `primaryHint`, else one with `isBinding: true` (the limit the user is hitting now, when the provider says so), else the window with the least left, else the first balance, else the first spend. The user can override it. Other windows become bars under the gauge (`meterLabel`), balances and spend become notes.
- **`menuBar: .tightest`** makes the menu bar show the lowest percentage among all readings instead of the primary, for providers whose real limit may not be the one on the gauge (Claude). It never overstates what is left.
- **`historyReadingID`** is the reading drawn as the provider's line in the logbook; every reading is stored per day.
- **`detail`** replaces the generated line ("27% used · 5h") for states numbers can't say: "New 5h window · starts with your next message".
- **Reading ids are stable**: users put them in `config.json` (`primary`, `limits`), and history is keyed by them.
- **`null` and missing are different.** Treat a field the provider sends as `null` as "none" (no window, no cap), not zero. Parse leniently: ignore fields you don't use, accept numbers sent as strings (`JSONValue.doubleValue` does).
- **Personal data.** Never put an email, login, user id or account name in a reading, label, note or error.

## 5. Errors

Throw `ProviderError`; its message is shown on the card as is, so write it for the user.

| Case | When | Message style |
| --- | --- | --- |
| `.notInstalled` | The tool isn't on this Mac | "Cursor is not installed" |
| `.notSignedIn` | No sign-in or no key | "No OpenRouter key set. Add one in settings." |
| `.expired` | The stored sign-in or key is expired or rejected | "Gemini CLI's sign-in has expired. Open Gemini CLI to sign in again." |
| `.rateLimited(retryAfter:)` | 429; the store waits for `Retry-After` | (generated) |
| `.unexpectedResponse` | The answer isn't what was expected; name what's missing | "OpenRouter's answer has no usage_monthly." |
| `.network`, `.timedOut` | Transport failures | (generated) |
| `.accessDenied` | The user denied a Keychain prompt; not retried until they press Refresh | |
| `.notConfigured` | A required setting is missing | "xAI needs a team id in its settings." |
| `.paymentRequired` | 402: out of balance, or the plan doesn't include this API | "<Provider> says the balance is used up." |
| `.notFound` | 404: an unknown id, or the feature isn't enabled | "<Provider> doesn't know that account id. Check it in settings." |

`HTTPClient` already maps 401 to `.notSignedIn`, 402 to `.paymentRequired`, 403 to `.expired`, 404 to `.notFound`, 429 to `.rateLimited`, 5xx to `.network` and anything else to `.unexpectedResponse`. A provider that uses another tool's sign-in turns 401 into `.expired` too ("open <tool> to sign in again"): only that tool can renew it. Catch and rethrow with a better message when you know more ("OpenRouter rejected the key"). For APIs that return errors with HTTP 200, check the body (`okWhen` in a definition). Never put the key, a token or a header value in a message.

## 6. Rules

1. Declare every host in `allowedHosts`; the client refuses the rest. HTTPS only, except `http://localhost` and `http://127.0.0.1`.
2. Pasted keys and cookies live only in the Keychain under Dogwatch's own service, read through `context.key()`, sent only in a request header. Never in a URL, a body (except where the provider's API demands it), `config.json`, history, an error or a log.
3. Another tool's files, Keychain items and databases are read-only. Nothing in `LocalTools` can write; keep it that way. `ToolStore.access` is always `.readOnly`.
4. Never refresh, rotate or create a login, never start a login flow, never open a browser (section 2).
5. Start a program only through a `DeclaredCommand`.
6. Label stability honestly; `unverified` until checked against a real account.
7. No guessed numbers (section 4).
8. Set `minimumRefreshInterval` to respect the provider's rate limit, at least 30 seconds.
9. Don't log. There is no logging in the app, and providers don't add any.

The contract tests (`ProviderContractTests` and the helpers in `Tests/DogwatchTests/Support/ProviderTestSupport.swift`) check these mechanically for every registered provider.

## 7. Files

A Swift provider adds:

```
Sources/Dogwatch/Providers/<Name>Provider.swift
Tests/DogwatchTests/Providers/<Name>ProviderTests.swift
Tests/DogwatchTests/Fixtures/<id>/*.json        # sample answers; never real account data
```

A declarative provider adds:

```
Sources/Dogwatch/Providers/Declarative/<Name>Definition.swift
Tests/DogwatchTests/Providers/<Name>DefinitionTests.swift
Tests/DogwatchTests/Fixtures/<id>/*.json
```

Then one line in `Sources/Dogwatch/Providers/ProviderRegistry.swift`, kept sorted by id so additions from several people merge cleanly:

```swift
static let builtIn: [any UsageProvider] = [
    ClaudeProvider(),
    CodexProvider(),
    DeclarativeProvider(definition: DeclarativeProviders.deepseek),   // a declarative one
    GrokProvider(),
    OpenRouterProvider(),
]
```

And one row in the README's providers table: run `swift test --filter ReadmeProviderTableTests`; when it fails it prints the whole table to paste between the markers. That's the only file outside your own that changes. New providers start switched off; only Codex, Claude and Grok are on for new users.

## 8. Tests and previews

Copy `Tests/DogwatchTests/Providers/OpenRouterProviderTests.swift` and keep its shape:

- `assertFollowsRules(provider)`: the descriptor rules.
- One test per fixture shape you have seen or the documentation shows: the readings you expect (ids, amounts in converted units, percentages only where real), the primary, the instrument's detail and menu value.
- The request: method, the key in the right header and nowhere else (`ProviderContract.violations(in:descriptor:key:)` must be empty).
- `await assertMapsHTTPErrors(provider, url:, key:)`: 401, 403, 429, 500, non-JSON and offline become the right typed errors, with no key in any message. For another tool's sign-in, `assertMapsHTTPErrors(provider, url:, credential: .storedSignIn(secret: token) { transport in TestContext.make(…, transport: transport, home: home) })` expects 401 and 403 both to be `expired` and to say "sign in again" (see `CopilotProviderTests`, `KiroProviderTests`).
- A missing key or sign-in fails with no request at all.
- For another tool's login: an expired stored token gives "sign in again" with no request and no process (`RecordingGate`, `FixtureTransport`); see `SubscriptionProviderTests` and `StoreTests.testAnExpiredStoredTokenShowsSignInAgainWithNoRequestAndNoProcess`.

Tools in the test support:

| Helper | Does |
| --- | --- |
| `Fixture.data("id/file.json")`, `Fixture.json(...)` | Reads a fixture from the source tree. |
| `FixtureTransport` | Answers requests by URL prefix from fixtures or bytes, records every request, can fail like a network. |
| `RecordingGate` | Records every attempt to start a program and refuses it. |
| `TestContext.make(for:transport:key:home:gate:settings:now:)` | A provider context wired to those. |
| `FakeProvider` | A provider returning a given snapshot or error, for store and layout tests. |

Run only your tests:

```sh
swift test --filter DeepSeekDefinitionTests
```

Render your provider in every design, with sample data, by adding it to a preview test and running:

```sh
DOGWATCH_DESIGN_PREVIEWS=/tmp/previews swift test --filter StoreTests
```

`StoreTests.testBalancesAndSpendRenderInEveryDesign` shows how; set `.environment(\.renderingStillImage, true)` when rendering lists long enough to scroll.

## 9. Checklist

- [ ] Kind chosen per section 1; the source is the safest one per section 2.
- [ ] `id` is final, lowercase, follows the billed account.
- [ ] `stability` is honest; `unverified` unless checked against a real account.
- [ ] `reads` says exactly what is read and where it goes; `source` and `summary` filled.
- [ ] Every host declared; HTTPS only.
- [ ] Key or cookie: `KeySpec` with `warning` if it can do more than read usage, `advice` for a narrower key.
- [ ] Another tool's login: read as stored, expiry checked locally, no refresh, "sign in again" when expired.
- [ ] Commands: declared, read-only per the tool's docs, reason written.
- [ ] Units converted once; percentages only from real totals; `null` means none.
- [ ] Reading ids stable; `primaryHint`, `isBinding`, `menuBar`, `historyReadingID` set where they matter.
- [ ] `minimumRefreshInterval` respects the provider's rate limit.
- [ ] No personal data in readings, labels, notes or errors.
- [ ] Fixtures are sample values, never real account data.
- [ ] Tests per section 8 pass; `swift test` passes as a whole.
- [ ] One registry line, sorted; the README row pasted from the test.

## 10. Templates

A Swift provider:

```swift
import SwiftUI

// <Name>: what it reads and why this source.
// API reference, read <date>: <URL>

struct ExampleProvider: UsageProvider {
    let descriptor = ProviderDescriptor(
        id: "example",
        name: "Example",
        glyph: ProviderGlyph(symbol: "creditcard"),
        tint: .teal,
        category: .api,
        stability: .unverified,
        credential: .pastedKey(KeySpec(label: "API key", placeholder: "ex-…", helpURL: URL(string: "https://example.com/keys"))),
        summary: "Prepaid balance",
        reads: "One GET to https://api.example.com/v1/balance, with your key from the Keychain in the Authorization header.",
        source: "Example API `GET /v1/balance`",
        allowedHosts: ["api.example.com"],
        minimumRefreshInterval: 60,
        idleLabel: "Add an API key"
    )

    func availability(in context: ProviderContext) -> ProviderAvailability {
        keyAvailability(in: context)
    }

    func fetch(in context: ProviderContext) async throws -> ProviderSnapshot {
        guard let key = context.key(), !key.isEmpty else { throw ProviderError.notSignedIn("No Example key set. Add one in settings.") }
        let json = try await context.http.getJSON(URL(string: "https://api.example.com/v1/balance")!, headers: ["Authorization": "Bearer \(key)"])
        guard let cents = json.value(at: "data.balance_cents")?.doubleValue else {
            throw ProviderError.unexpectedResponse("Example's answer has no data.balance_cents.")
        }
        return ProviderSnapshot(readings: [Reading(
            id: "balance", name: "Balance",
            value: .balance(Balance(remaining: Amount(value: cents / 100, unit: .currency("USD"))))
        )], fetchedAt: context.now())
    }
}
```

A declarative definition:

```swift
extension DeclarativeProviders {
    /// Example: prepaid balance in cents.
    /// API reference, read <date>: <URL>
    static let example = """
    {
      "id": "example",
      "name": "Example",
      "stability": "unverified",
      "summary": "Prepaid balance",
      "source": "Example API `GET /v1/balance`",
      "documentation": "https://example.com/docs/balance",
      "glyph": "creditcard",
      "keyHelpURL": "https://example.com/keys",
      "url": "https://api.example.com/v1/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance", "name": "Balance", "kind": "balance",
          "remaining": "data.balance_cents", "unit": "USD", "scale": 0.01 }
      ]
    }
    """
}
```

`Providers/Declarative/DeepSeekDefinition.swift` and the other definitions next to it are real examples of each option below.

Keys only built-in definitions use: `stability`, `summary`, `source`, `documentation`, `glyph`, `keyLabel`, `keyPlaceholder`, `keyHelpURL`, `keyWarning`, `keyAdvice`, `category` (`subscription` or `api`), `baseURLs` (`[{label, url, unit?}]`, with `{baseURL}` in `url`), `customBaseURL` and `fields` (`[{id, label, placeholder, help}]`, with `{field:<id>}` in `url`). Every key below works in a user's `customProviders` too.

### Declarative options

| Option | Where | Does | Example |
| --- | --- | --- | --- |
| `[field=value]` in a path | any path | Picks the first array element whose `field` equals `value` (compared as text). A path without it resolves exactly as before. | DeepSeek: `balance_infos[currency=USD].total_balance` |
| `optional: true` | reading | A missing value (or a filter that matches nothing) leaves the reading out instead of failing the fetch. Use it for parts of an answer that come and go, and for one of two answer shapes. A reading that isn't optional still fails with "no value at <path>". | Vercel's Token Pass; Ollama's current and legacy plans |
| `remainingPercent` | window reading | A percentage left (0–100, or a fraction with `fraction: true`), instead of `usedPercent`. | Ollama legacy `session.remaining_percent` |
| `reset` on a balance | balance reading | Now also sets when a balance refills (it was ignored on balances before). | Ollama's included credits, `period.until` |
| `nullIsZero: true` | reading | `null` counts as 0 instead of "none", for APIs that document "null when zero". | Venice `balances.usd` |
| `meterLabel` | reading | The short label when the reading is a second meter. | Ollama "Week" |
| `"unit": "{baseURL.unit}"` with `baseURLs[].unit` | reading | The unit of the region the user picked, for endpoints whose currency depends on the host. Every `baseURLs` entry must then name a unit; a base URL that matches none is a "not configured" error, never a guessed unit. | Moonshot: USD on `.ai`, CNY on `.cn` |
| `customBaseURL: true` | definition | The user enters the base URL (a self-hosted gateway). `url` must start with `{baseURL}`; `baseURLs` may be empty, and then the user's URL is required. HTTPS, or HTTP to `localhost` and `127.0.0.1`. | LiteLLM `{baseURL}/key/info` |
| `primaryFrom` | definition | `{"path": …, "readings": {value: readingID}}` picks the primary from a value in the answer; falls back to `primary`, then the usual rule. | Venice `consumptionCurrency` |
| `minimumRefreshMinutes` | definition | Never fetched more often than this (0.5 or more; default 1), for rate-limited endpoints. | Ollama: 2 |
| `keyAdvice`, `keyPlaceholder` | definition | The `KeySpec` fields of the same name: which narrower key to prefer (or that none exists), and a harmless example of the key's shape. | fal: "a key with the BILLING preset" |
| `keyKind` | definition | What the user pastes: `apiKey` (default), `adminKey`, `token` or `cookie`. Settings labels the field and its warning to match. | |
| `{field:<id>}` in a header | `headers` | A non-secret setting sent as a header (an organisation or project id). Every `{field:…}` must be declared in `fields`; an empty setting leaves its header out; a header can't mix `{key}` and a setting. | `"X-Organization": "{field:org}"` |
| `"period": "$.path"` | reading | A period starting with `$` is read from the answer ("monthly", "billing period") instead of fixed text. Missing is an error, unless the reading is `optional`. | ElevenLabs-style `character_refresh_period` |
| `tint` | definition | The provider's colour, `#RRGGBB`. Without it, one is picked from the id; built-in providers each set their own, and `ProviderContractTests` refuses two providers with the same glyph or the same tint. | DeepSeek `#4D6BFE` |
| `okWhen`, `errorMessage` | definition | For APIs that answer errors with HTTP 200: `{"path": …, "equals": …}` must hold, else the text at `errorMessage` becomes the error. | |
| `scale`, `flipSign`, `fraction`, `resetFormat` | reading | Multiply a value (`0.01` for cents); negate it (balances reported as negative debt); read a percentage given as 0–1; parse resets as `iso8601`, `unixSeconds` or `unixMs` (default `auto`). | Novita `0.0001` |

Units are where definitions go wrong: write the scale beside the field it applies to (`0.01` for cents, `0.0001` for Novita's 1/10,000 of a dollar), and give each definition a test whose fixture would catch a factor of 100. If neither the answer nor the documentation states a currency, don't write one: leave the provider out.

## 11. What the foundation doesn't do yet

Found while checking the model against the provider research. None blocks a provider, but each limits what it can show:

- **Window kinds.** A window's period is a duration or a name; whether it is rolling or calendar-anchored, and its start time, aren't modelled. Put it in `name` or `detail` if it matters.
- **Balance expiry.** Credits that expire (Amp, Kiro add-ons) have no expiry field. Use a `note`.
- **"Can I use it now".** A provider's own blocked/allowed flag (Codex's `ordinaryUsageAllowed`, Claude's `locked_reason`) has no place of its own. Use `detail` or a `note`.
- **Several accounts of one provider** (two GitHub logins, several Devin organisations) need one provider id each, or a field to pick one.
- **Declarative sums and pages.** Definitions can't sum arrays, follow pagination, compute dates such as the start of the month, or make a second request. Write a Swift provider (Deepgram sums its balances per unit).
- **Decrypting Electron "Safe Storage" tokens** (Cursor, Devin) needs CommonCrypto code inside the provider and a Keychain prompt; it's allowed, behind `mayPrompt` and `.accessDenied`, but there is no shared helper.
- **A credential source picker** (Auto, tool sign-in, pasted key, off). A provider can declare `optionalKey` and decide in `fetch`; there is no shared picker.
