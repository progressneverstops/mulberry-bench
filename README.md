# MulberryBench

A small, dependency-free AI benchmark you **run yourself**. It's the open version of
the on-device capability check inside [Mulberry](https://mulberryide.com) — pulled out
so you don't have to take anyone's word for the numbers.

No account. No sign-up. No SDK. Local runs make **zero network calls** and need **no key**.

```bash
git clone https://github.com/progressneverstops/mulberry-bench && cd mulberry-bench
swift run mulberry-bench --suite ollama     # 100% local, offline
```

---

## Don't trust it — verify it

This is built for people who assume "platform" means "phone-home until proven otherwise."
So here's how to prove otherwise, in about two minutes:

1. **Read it.** It's one file: [`Sources/mulberry-bench/main.swift`](Sources/mulberry-bench/main.swift).
   Pure `Foundation` + `URLSession`. No dependencies (`Package.swift` has none), no analytics SDK.

2. **No key ships in this repo.** The app's free tier uses a shared key; this repo does not.
   Check for yourself:
   ```bash
   grep -r "sk-or-v1" .        # → nothing
   ```
   Cloud providers are **bring-your-own-key**, via env vars only (below).

3. **Watch the network.** Run the local suite with a packet sniffer open, or in Airplane Mode:
   ```bash
   swift run mulberry-bench --suite ollama
   ```
   The only host it talks to is `localhost:11434` (your own Ollama). Nothing leaves the machine.

4. **It can't talk to us.** There is no Mulberry endpoint in this code. Grep for our domain:
   ```bash
   grep -rn "mulberry" Sources/    # → a referer header string on cloud calls, nothing more
   ```

## What actually leaves your machine

| Suite | Talks to | Sends |
|---|---|---|
| `ollama` | `localhost` (your machine) | nothing — fully offline |
| `api` / `code` / `context` / `full` | the cloud provider **you** set a key for | your prompt → that provider. Never to us. |

If you only run `ollama`, this program is incapable of making an outbound internet request.

## Run it

**Local (offline, no key):**
```bash
# one-time: install + pull a model
brew install ollama && ollama serve
ollama pull phi3:mini        # or tinyllama, qwen:0.5b, gemma:2b …

swift run mulberry-bench --suite ollama
```

**Cloud (optional, your own keys):**
```bash
export OPENROUTER_KEY=sk-or-...      # or OPENAI_KEY / ANTHROPIC_KEY / MISTRAL_KEY / GEMINI_KEY
swift run mulberry-bench --suite api
```

**Other suites:** `code`, `context`, `rotation`, `concurrency`, `optimize`, `alt`, `full`.
Add `--json-only` for machine-readable output.

## Output

Written to the current directory, nowhere else:
- `results/benchmark_<timestamp>.json` — full run
- `BENCHMARK_RESULTS.md` — cumulative human-readable table

## In Xcode

`open Package.swift`, pick the **mulberry-bench** scheme, Product → Run. Output goes to the
console. (It's a command-line tool — there's no UI; that lives in the app.)

## Why this exists

Mulberry's whole point is AI you can inspect and run locally — on-device, offline, no
black box. A benchmark you can only read about proves nothing. This one you clone, read,
and run. The numbers are yours.

---

MIT-licensed. The benchmark is open; the app it came from is source-available.
