//
//  benchmark_runner.swift
//  PrivateViewer / HTMLViewer — Comprehensive AI Benchmark Suite
//
//  Run from terminal (no Xcode required):
//    swift bts/benchmark_runner.swift
//    swift bts/benchmark_runner.swift --suite zazu
//    swift bts/benchmark_runner.swift --suite api
//    swift bts/benchmark_runner.swift --suite context
//    swift bts/benchmark_runner.swift --suite full          (default)
//    swift bts/benchmark_runner.swift --json-only           (machine-readable)
//
//  API key resolution (in priority order):
//    1. Env var  OPENROUTER_KEY, OPENAI_KEY, ANTHROPIC_KEY, MISTRAL_KEY, GEMINI_KEY
//    2. Built-in Zazu key (OpenRouter free-tier only, matches FreeOrchestrator.swift)
//
//  Output:
//    • Colour-coded terminal table
//    • bts/results/benchmark_YYYYMMDD_HHmmss.json
//    • bts/BENCHMARK_RESULTS.md  (cumulative, prepends newest run)
//

import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ANSI colours
// ─────────────────────────────────────────────────────────────────────────────

struct C {
    private static let ESC    = "\u{001B}"
    private static let RESET  = "\u{001B}[0m"
    private static let BOLD   = "\u{001B}[1m"
    private static let DIM    = "\u{001B}[2m"
    private static let GREEN  = "\u{001B}[32m"
    private static let YELLOW = "\u{001B}[33m"
    private static let RED    = "\u{001B}[31m"
    private static let CYAN   = "\u{001B}[36m"
    private static let GRAY   = "\u{001B}[90m"

    static func ok(_ s: String)   -> String { "\(GREEN)\(s)\(RESET)" }
    static func warn(_ s: String) -> String { "\(YELLOW)\(s)\(RESET)" }
    static func err(_ s: String)  -> String { "\(RED)\(s)\(RESET)" }
    static func hdr(_ s: String)  -> String { "\(BOLD)\(CYAN)\(s)\(RESET)" }
    static func dim(_ s: String)  -> String { "\(DIM)\(s)\(RESET)" }
    static func bold(_ s: String) -> String { "\(BOLD)\(s)\(RESET)" }
    static func cyan(_ s: String) -> String { "\(CYAN)\(s)\(RESET)" }
    static func gray(_ s: String) -> String { "\(GRAY)\(s)\(RESET)" }
}

func banner(_ text: String) {
    let line = String(repeating: "─", count: 70)
    print("\n\(C.hdr(line))")
    print(C.hdr("  \(text)"))
    print(C.hdr(line))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Config
// ─────────────────────────────────────────────────────────────────────────────

struct Config {
    // Built-in Zazu tier key — read from env first for flexibility.
    // Matches FreeOrchestrator.swift zazuAPIKey field.
    static let zazuKey: String =
        ProcessInfo.processInfo.environment["OPENROUTER_KEY"]
        ?? ""   // BYOK only — set OPENROUTER_KEY; no key ships in this repo

    static let openAIKey:    String? = ProcessInfo.processInfo.environment["OPENAI_KEY"]
    static let anthropicKey: String? = ProcessInfo.processInfo.environment["ANTHROPIC_KEY"]
    static let mistralKey:   String? = ProcessInfo.processInfo.environment["MISTRAL_KEY"]
    static let geminiKey:    String? = ProcessInfo.processInfo.environment["GEMINI_KEY"]

    static let openRouterEndpoint = "https://openrouter.ai/api/v1/chat/completions"
    static let openAIEndpoint     = "https://api.openai.com/v1/chat/completions"
    static let anthropicEndpoint  = "https://api.anthropic.com/v1/messages"
    static let mistralEndpoint    = "https://api.mistral.ai/v1/chat/completions"
    static let geminiEndpoint     = "https://generativelanguage.googleapis.com/v1beta/models"

    // Output paths (relative to working dir)
    static let resultsDir   = "results"
    static let summaryPath  = "BENCHMARK_RESULTS.md"
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Data models
// ─────────────────────────────────────────────────────────────────────────────

struct ModelTarget {
    let displayName: String
    let modelID: String
    let provider: String
    let endpoint: String
    let apiKey: String
    let tier: String          // "free", "paid", "local"
    let contextWindow: Int    // tokens
    let notes: String
}

struct RunResult: Codable {
    let modelID: String
    let displayName: String
    let promptLabel: String
    let promptTokensEst: Int
    let success: Bool
    let httpStatus: Int
    let ttftMs: Int           // time-to-first-token, -1 if N/A
    let totalMs: Int
    let responseChars: Int
    let responseTokensEst: Int
    let tokPerSecEst: Double
    let errorMessage: String
    let timestamp: String
}

struct BenchmarkReport: Codable {
    let runID: String
    let startedAt: String
    let finishedAt: String
    let suiteName: String
    let hostMachine: String
    let swiftVersion: String
    let results: [RunResult]
    var summaryStats: [String: String]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Prompts
// ─────────────────────────────────────────────────────────────────────────────

struct Prompt {
    let label: String
    let text: String
    var estTokens: Int { max(1, text.count / 4) }
}

let PROMPTS_SHORT: [Prompt] = [
    Prompt(label: "ping",     text: "Reply with exactly: OK"),
    Prompt(label: "math",     text: "What is 17 * 23? Just the number."),
    Prompt(label: "swift-1",  text: "Write a 1-line Swift function that reverses a String."),
]

let PROMPTS_MEDIUM: [Prompt] = [
    Prompt(label: "swift-fn",  text: "Write a Swift function that binary-searches a sorted [Int] array. Include type annotations and return nil if not found."),
    Prompt(label: "explain",   text: "Explain in 3 bullet points why Swift's actor model prevents data races in concurrent code."),
    Prompt(label: "html-comp", text: "Write a minimal responsive HTML card component with a title, subtitle, and a CTA button. Use inline CSS only."),
]

let PROMPTS_CODE_GEN: [Prompt] = [
    Prompt(label: "viewmodel", text: "Write a complete SwiftUI ViewModel (ObservableObject) for a simple todo list: add, toggle, delete items. Use @Published properties."),
    Prompt(label: "async-net", text: "Write a Swift async/await networking layer that fetches JSON from a URL, decodes into a generic Codable type, and retries once on error."),
]

// Context scaling: inject N words of filler then ask a question
func contextScalePrompt(targetTokens: Int) -> Prompt {
    let filler = Array(repeating: "The quick brown fox jumps over the lazy dog.", count: targetTokens / 10).joined(separator: " ")
    return Prompt(
        label: "ctx-\(targetTokens)t",
        text: "\(filler)\n\nGiven the above text, how many times does the word 'fox' appear? Just the integer."
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - HTTP helper
// ─────────────────────────────────────────────────────────────────────────────

func postJSON(
    url: String,
    headers: [String: String],
    body: [String: Any],
    timeoutSeconds: TimeInterval = 45
) -> (data: Data?, statusCode: Int, error: String?) {
    guard let urlObj = URL(string: url) else {
        return (nil, 0, "Invalid URL: \(url)")
    }

    var req = URLRequest(url: urlObj)
    req.httpMethod = "POST"
    req.timeoutInterval = timeoutSeconds
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    guard JSONSerialization.isValidJSONObject(body),
          let bodyData = try? JSONSerialization.data(withJSONObject: body)
    else { return (nil, 0, "Invalid JSON body") }
    req.httpBody = bodyData

    let sem = DispatchSemaphore(value: 0)
    var resultData: Data?
    var statusCode = 0
    var errStr: String?

    let task = URLSession.shared.dataTask(with: req) { data, resp, err in
        if let http = resp as? HTTPURLResponse { statusCode = http.statusCode }
        resultData = data
        if let err { errStr = err.localizedDescription }
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeoutSeconds + 5) == .timedOut {
        task.cancel()
        errStr = "Request timed out after \(Int(timeoutSeconds))s"
    }
    return (resultData, statusCode, errStr)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Core benchmark runner
// ─────────────────────────────────────────────────────────────────────────────

func runOnce(target: ModelTarget, prompt: Prompt, timeoutSeconds: TimeInterval = 45) -> RunResult {
    let start = Date()
    let ts = ISO8601DateFormatter().string(from: start)

    let messages: [[String: Any]] = [
        ["role": "user", "content": prompt.text]
    ]

    var body: [String: Any] = [
        "model":       target.modelID,
        "messages":    messages,
        "temperature": 0.3,
        "max_tokens":  512,
    ]

    var headers: [String: String] = [
        "Authorization": "Bearer \(target.apiKey)",
        "HTTP-Referer":  "https://mulberryide.com",
        "X-Title":       "PrivateViewer-Benchmark",
    ]

    // Anthropic uses different format
    if target.provider == "anthropic" {
        headers["x-api-key"] = target.apiKey
        headers.removeValue(forKey: "Authorization")
        headers["anthropic-version"] = "2023-06-01"
        body = [
            "model":      target.modelID,
            "max_tokens": 512,
            "messages":   messages,
        ]
    }

    let (data, status, netErr) = postJSON(url: target.endpoint, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    let elapsed = Int(Date().timeIntervalSince(start) * 1000)

    // Parse response text
    var responseText = ""
    var parseErr = ""

    if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let choices = json["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let content = msg["content"] as? String {
            responseText = content
        } else if let content = json["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String {
            // Anthropic format
            responseText = text
        } else if let errObj = json["error"] as? [String: Any],
                  let msg = errObj["message"] as? String {
            parseErr = "API error: \(msg)"
        } else {
            parseErr = "Unexpected JSON shape"
        }
    } else if let netErr {
        parseErr = netErr
    } else {
        parseErr = status != 0 ? "HTTP \(status) — no parseable body" : "No response"
    }

    let ok = status >= 200 && status < 300 && !responseText.isEmpty
    let chars = responseText.count
    let estTokens = max(1, chars / 4)
    let tokPerSec = elapsed > 0 ? Double(estTokens) / (Double(elapsed) / 1000.0) : 0

    return RunResult(
        modelID:           target.modelID,
        displayName:       target.displayName,
        promptLabel:       prompt.label,
        promptTokensEst:   prompt.estTokens,
        success:           ok,
        httpStatus:        status,
        ttftMs:            elapsed,   // we can't stream here; total time ≈ TTFT proxy
        totalMs:           elapsed,
        responseChars:     chars,
        responseTokensEst: estTokens,
        tokPerSecEst:      tokPerSec,
        errorMessage:      ok ? "" : parseErr.isEmpty ? "HTTP \(status)" : parseErr,
        timestamp:         ts
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Multi-run averaged benchmark
// ─────────────────────────────────────────────────────────────────────────────

func runBench(
    target: ModelTarget,
    prompts: [Prompt],
    iterations: Int = 2,
    label: String,
    timeoutSeconds: TimeInterval = 45
) -> [RunResult] {
    var results: [RunResult] = []
    for p in prompts {
        print("  \(C.dim("[\(label)]")) \(target.displayName) / \(p.label) … ", terminator: "")
        fflush(stdout)
        var best: RunResult?
        for i in 0..<iterations {
            let r = runOnce(target: target, prompt: p, timeoutSeconds: timeoutSeconds)
            if i == 0 || r.success {
                if best == nil || (r.success && r.totalMs < (best?.totalMs ?? Int.max)) {
                    best = r
                }
            }
            // Brief pause between iterations to avoid rate limit
            if i < iterations - 1 { Thread.sleep(forTimeInterval: 1.5) }
        }
        let r = best!
        let status = r.success
            ? C.ok("✓ \(r.totalMs)ms \(String(format: "%.1f", r.tokPerSecEst))t/s")
            : C.err("✗ \(r.errorMessage)")
        print(status)
        results.append(r)
    }
    return results
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Model target catalog
// ─────────────────────────────────────────────────────────────────────────────

// Legacy pool (FreeOrchestrator.swift original — mostly dead as of 2026-06-03)
func zazuTargetsLegacy() -> [ModelTarget] {
    let key = Config.zazuKey
    let ep  = Config.openRouterEndpoint
    return [
        ModelTarget(displayName: "Zazu/Qwen",     modelID: "qwen/qwen3-coder:free",          provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "429 rate-limited"),
        ModelTarget(displayName: "Zazu/OwlAlpha", modelID: "openrouter/owl-alpha",            provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "Working"),
        ModelTarget(displayName: "Zazu/MiMo",     modelID: "minimax/minimax-m2.5:free",       provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 16384, notes: "404 dead"),
        ModelTarget(displayName: "Zazu/GPT-OSS",  modelID: "openai/gpt-oss-20b:free",         provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 16384, notes: "503 down"),
        ModelTarget(displayName: "Zazu/DeepSeek", modelID: "deepseek/deepseek-v4-flash:free", provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "404 dead"),
    ]
}

// Active pool — verified working 2026-06-03
func zazuTargets() -> [ModelTarget] {
    let key = Config.zazuKey
    let ep  = Config.openRouterEndpoint
    return [
        ModelTarget(displayName: "Laguna-xs",    modelID: "poolside/laguna-xs.2:free",  provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "Fastest ping (660ms)"),
        ModelTarget(displayName: "GLM-4.5-air",  modelID: "z-ai/glm-4.5-air:free",      provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "Best throughput 15-20 t/s"),
        ModelTarget(displayName: "Kimi-k2.5",    modelID: "moonshotai/kimi-k2.5",        provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 128000,notes: "100% reliable"),
        ModelTarget(displayName: "GLM-5-turbo",  modelID: "z-ai/glm-5-turbo",            provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "Backup slot"),
        ModelTarget(displayName: "OwlAlpha",     modelID: "openrouter/owl-alpha",         provider: "openrouter", endpoint: ep, apiKey: key, tier: "free", contextWindow: 32768, notes: "Context fallback"),
    ]
}

func openRouterPaidTargets() -> [ModelTarget] {
    guard let key = Config.openAIKey ?? (Config.zazuKey.isEmpty ? nil : Config.zazuKey) else { return [] }
    let ep = Config.openRouterEndpoint
    return [
        ModelTarget(displayName: "OR/Claude-Sonnet", modelID: "anthropic/claude-sonnet-4-5", provider: "openrouter", endpoint: ep, apiKey: key, tier: "paid", contextWindow: 200000, notes: "Via OpenRouter"),
        ModelTarget(displayName: "OR/GPT-4o",        modelID: "openai/gpt-4o",               provider: "openrouter", endpoint: ep, apiKey: key, tier: "paid", contextWindow: 128000, notes: "Via OpenRouter"),
        ModelTarget(displayName: "OR/DeepSeek-R1",   modelID: "deepseek/deepseek-r1",        provider: "openrouter", endpoint: ep, apiKey: key, tier: "paid", contextWindow: 64000,  notes: "Reasoning model"),
    ]
}

func cloudTargets() -> [ModelTarget] {
    var t: [ModelTarget] = []
    if let key = Config.openAIKey {
        t.append(ModelTarget(displayName: "OpenAI/GPT-4.1-nano", modelID: "gpt-4.1-nano",       provider: "openai",     endpoint: Config.openAIEndpoint,    apiKey: key, tier: "paid", contextWindow: 1047576, notes: "App primary OpenAI"))
    }
    if let key = Config.anthropicKey {
        t.append(ModelTarget(displayName: "Anthropic/Sonnet",    modelID: "claude-3-5-sonnet-latest", provider: "anthropic", endpoint: Config.anthropicEndpoint, apiKey: key, tier: "paid", contextWindow: 200000, notes: "App Anthropic model"))
    }
    if let key = Config.mistralKey {
        t.append(ModelTarget(displayName: "Mistral/Small",       modelID: "mistral-small",       provider: "mistral",    endpoint: Config.mistralEndpoint,   apiKey: key, tier: "paid", contextWindow: 32768,  notes: "Mistral self-custody"))
        t.append(ModelTarget(displayName: "Mistral/Devstral",    modelID: "devstral-2512",        provider: "mistral",    endpoint: Config.mistralEndpoint,   apiKey: key, tier: "paid", contextWindow: 32768,  notes: "Mistral code model"))
    }
    return t
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Suite runners
// ─────────────────────────────────────────────────────────────────────────────

func suiteZazuPool() -> [RunResult] {
    banner("Suite 1 · Zazu Free Pool — All 5 Slots")
    let targets = zazuTargets()
    var all: [RunResult] = []
    for t in targets {
        print("\n\(C.bold("\(t.displayName)")) \(C.gray("[\(t.modelID)]"))")
        all += runBench(target: t, prompts: PROMPTS_SHORT, iterations: 1, label: "zazu-short")
        Thread.sleep(forTimeInterval: 2.0)
        all += runBench(target: t, prompts: [PROMPTS_MEDIUM[0]], iterations: 1, label: "zazu-code")
        Thread.sleep(forTimeInterval: 2.0)
    }
    return all
}

func suiteAPILatency() -> [RunResult] {
    banner("Suite 2 · API Latency — Short + Medium prompts")
    let targets = cloudTargets() + openRouterPaidTargets()
    guard !targets.isEmpty else {
        print(C.warn("  No cloud API keys found. Set OPENAI_KEY, ANTHROPIC_KEY, MISTRAL_KEY to enable."))
        return []
    }
    var all: [RunResult] = []
    for t in targets {
        print("\n\(C.bold("\(t.displayName)")) \(C.gray("[\(t.modelID)]"))")
        all += runBench(target: t, prompts: PROMPTS_SHORT + PROMPTS_MEDIUM, iterations: 2, label: "api")
        Thread.sleep(forTimeInterval: 1.5)
    }
    return all
}

func suiteCodeThroughput() -> [RunResult] {
    banner("Suite 3 · Code Generation Throughput")
    let targets = zazuTargets().prefix(2).map { $0 } + cloudTargets()
    var all: [RunResult] = []
    for t in targets {
        print("\n\(C.bold("\(t.displayName)"))")
        all += runBench(target: t, prompts: PROMPTS_CODE_GEN, iterations: 1, label: "codegen")
        Thread.sleep(forTimeInterval: 2.5)
    }
    return all
}

func suiteContextScaling() -> [RunResult] {
    banner("Suite 4 · Context Window Scaling")
    print(C.dim("  Tests how latency scales at 100 / 500 / 1000 / 2000 estimated tokens"))
    let tokenSizes = [100, 500, 1000, 2000]
    let scalingPrompts = tokenSizes.map { contextScalePrompt(targetTokens: $0) }

    // Use first available Zazu slot + first cloud target if available
    var targets: [ModelTarget] = [zazuTargets()[0]]
    if let cloud = cloudTargets().first { targets.append(cloud) }

    var all: [RunResult] = []
    for t in targets {
        print("\n\(C.bold("\(t.displayName)"))")
        all += runBench(target: t, prompts: scalingPrompts, iterations: 1, label: "ctx-scale")
        Thread.sleep(forTimeInterval: 2.0)
    }
    return all
}

func suiteFreeOrchRotation() -> [RunResult] {
    banner("Suite 5 · FreeOrchestrator Rotation — Exhaustion Probe")
    print(C.dim("  Sends 20 rapid requests round-robin to simulate rotation logic"))
    let pool = zazuTargets()
    var all: [RunResult] = []
    let probe = PROMPTS_SHORT[0]  // fastest possible prompt

    for i in 0..<20 {
        let t = pool[i % pool.count]
        print("  \(C.dim("req \(i+1)/20")) \(t.displayName) … ", terminator: "")
        fflush(stdout)
        let r = runOnce(target: t, prompt: probe)
        let st = r.success ? C.ok("✓ \(r.totalMs)ms") : C.err("✗ \(r.errorMessage)")
        print(st)
        all.append(r)
        Thread.sleep(forTimeInterval: 0.8)
    }
    return all
}

func suiteConcurrency() -> [RunResult] {
    banner("Suite 6 · Concurrency — 3 Parallel Requests")
    print(C.dim("  Fires 3 simultaneous requests to the same model. Simulates ConcurrentRequestUI."))
    let t = zazuTargets()[0]
    var all: [RunResult] = []
    var results: [RunResult?] = [nil, nil, nil]
    let group = DispatchGroup()

    for i in 0..<3 {
        group.enter()
        DispatchQueue.global().async {
            let prompt = PROMPTS_MEDIUM[i % PROMPTS_MEDIUM.count]
            let r = runOnce(target: t, prompt: prompt)
            results[i] = r
            group.leave()
        }
    }

    let start = Date()
    group.wait()
    let wall = Int(Date().timeIntervalSince(start) * 1000)

    for (i, r) in results.enumerated() {
        guard let r else { continue }
        let st = r.success ? C.ok("✓ \(r.totalMs)ms") : C.err("✗ \(r.errorMessage)")
        print("  req \(i+1): \(r.promptLabel) → \(st)")
        all.append(r)
    }
    print("  \(C.cyan("Wall-clock for all 3 parallel:")) \(wall)ms")
    return all
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Alt model targets (ALT_MODELS_BENCHMARK.md models)
// ─────────────────────────────────────────────────────────────────────────────

func altModelTargets() -> [ModelTarget] {
    let k = Config.zazuKey
    let ep = Config.openRouterEndpoint
    return [
        ModelTarget(displayName: "Hermes2-Pro-8B",   modelID: "nousresearch/hermes-2-pro-llama-3-8b",          provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 8192,   notes: "Code + tool use"),
        ModelTarget(displayName: "MiMo-V2-Flash",    modelID: "xiaomi/mimo-v2-flash",                           provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 32768,  notes: "Code, high throughput"),
        ModelTarget(displayName: "Mistral-Saba",     modelID: "mistralai/mistral-saba",                         provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 32768,  notes: "Fast instruct 113 t/s"),
        ModelTarget(displayName: "Reka-Edge",        modelID: "rekaai/reka-edge",                               provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 128000, notes: "128K context"),
        ModelTarget(displayName: "Phi-4",            modelID: "microsoft/phi-4",                                provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 16384,  notes: "Quality reasoning"),
        ModelTarget(displayName: "Rocinante-12B",    modelID: "thedrummer/rocinante-12b",                       provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 8192,   notes: "Creative instruct"),
        ModelTarget(displayName: "EssentialAI-RNJ1", modelID: "essentialai/rnj-1-instruct",                     provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 32768,  notes: "Fast sub-500ms"),
        ModelTarget(displayName: "Mistral-Small-24B",modelID: "mistralai/mistral-small-24b-instruct-2501",      provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 32768,  notes: "Quality instruct"),
        ModelTarget(displayName: "LFM-1.2B-Instruct",modelID: "liquid/lfm-2.5-1.2b-instruct:free",             provider: "openrouter", endpoint: ep, apiKey: k, tier: "free", contextWindow: 32768,  notes: "Tiny, 178ms ping"),
        ModelTarget(displayName: "GPT-3.5-Turbo",    modelID: "openai/gpt-3.5-turbo",                           provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 16384,  notes: "Classic reliable"),
        ModelTarget(displayName: "DS-V4-Flash",      modelID: "deepseek/deepseek-v4-flash",                     provider: "openrouter", endpoint: ep, apiKey: k, tier: "paid", contextWindow: 65536,  notes: "Fast paid DeepSeek"),
    ]
}

func suiteAltModels() -> [RunResult] {
    banner("Suite 8 · Alternative Models (see ALT_MODELS_BENCHMARK.md)")
    print(C.dim("  Code gen / fast instruct / reasoning / tiny models"))
    let targets = altModelTargets()
    var all: [RunResult] = []
    let codePrompts = [PROMPTS_MEDIUM[0]] // swift-fn only for speed
    let shortPrompts = PROMPTS_SHORT      // ping + math + swift-1
    for t in targets {
        print("\n\(C.bold("\(t.displayName)")) \(C.gray("[\(t.modelID)]")) \(C.dim("\(t.notes)"))")
        all += runBench(target: t, prompts: shortPrompts, iterations: 1, label: "alt-short")
        Thread.sleep(forTimeInterval: 1.0)
        all += runBench(target: t, prompts: codePrompts, iterations: 1, label: "alt-code")
        Thread.sleep(forTimeInterval: 2.0)
    }
    return all
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Ollama local targets (GGUF/MLX candidate bundle models)
//
// Prerequisites — pull each model before running this suite:
//   ollama pull tinyllama          (~640MB,  1.1B Q4_K_M)
//   ollama pull qwen:0.5b          (~394MB,  0.5B Q4_K_M)
//   ollama pull phi                (~1.6GB,  2.7B Q4_K_M)
//   ollama pull gemma:2b           (~1.7GB,  2B   Q4)
//   ollama pull openchat           (~2.0GB,  3.5B Q4_K_M)
//   ollama pull stablelm2          (~1.1GB,  1.6B Q4_K_M)
//   ollama pull phi3:mini          (~2.2GB,  3.8B Q4_K_M)
//
// Ollama exposes OpenAI-compatible API at localhost:11434/v1 — no auth needed.
// ─────────────────────────────────────────────────────────────────────────────

func ollamaTargets() -> [ModelTarget] {
    let ep = "http://localhost:11434/v1/chat/completions"
    return [
        ModelTarget(displayName: "Qwen1.5-0.5B",   modelID: "qwen:0.5b",      provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 32768, notes: "~394MB • smallest viable"),
        ModelTarget(displayName: "TinyLlama-1.1B",  modelID: "tinyllama",      provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 2048,  notes: "~640MB • lightest chat"),
        ModelTarget(displayName: "StableLM2-1.6B",  modelID: "stablelm2",      provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 4096,  notes: "~1.1GB • zephyr instruct"),
        ModelTarget(displayName: "Phi-2-2.7B",      modelID: "phi",            provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 2048,  notes: "~1.6GB • MS coding"),
        ModelTarget(displayName: "Gemma-2B",         modelID: "gemma:2b",       provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 8192,  notes: "~1.7GB • Google"),
        ModelTarget(displayName: "OpenChat-3.5-3.5B",modelID: "openchat",       provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 8192,  notes: "~2.0GB • balanced"),
        ModelTarget(displayName: "Phi3-mini-3.8B",   modelID: "phi3",             provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 4096,   notes: "~2.2GB • Phi-3.5 predecessor"),
        ModelTarget(displayName: "Qwen2.5-Coder-7B", modelID: "qwen2.5-coder:7b", provider: "ollama", endpoint: ep, apiKey: "ollama", tier: "local", contextWindow: 128000, notes: "~4.7GB • ceiling reference"),
    ]
}

func ollamaAvailabilityProbe() -> [String: Bool] {
    var live: [String: Bool] = [:]
    let probe = PROMPTS_SHORT[0]
    print(C.dim("  Probing Ollama at localhost:11434 (60s timeout per model) …"))
    for t in ollamaTargets() {
        // Use 60s: enough for model cold-load on macOS CPU
        let r = runOnce(target: t, prompt: probe, timeoutSeconds: 60)
        live[t.modelID] = r.success
        let st = r.success ? C.ok("✓ \(r.totalMs)ms") : C.err("✗ \(r.errorMessage.prefix(80))")
        print("  \(t.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(st)")
    }
    return live
}

// Quality rubric for tiny models — tests where size matters most
let PROMPTS_TINY_QUALITY: [Prompt] = [
    Prompt(label: "math-chain",  text: "If a train leaves at 9am going 60mph and another leaves at 10am going 80mph, when does the second catch the first? Show working."),
    Prompt(label: "code-tiny",   text: "Write a Swift function that checks if a string is a palindrome. One function, no comments."),
    Prompt(label: "instruct",    text: "List 3 differences between value types and reference types in Swift. Be concise."),
]

func suiteOllamaLocal() -> [RunResult] {
    banner("Suite 9 · Ollama Local — Bundle Candidate Benchmarks")
    print(C.dim("  GGUF candidates for pre-packaging on first app launch"))
    print(C.dim("  Metrics: latency, t/s, quality rubric (math/code/instruct)"))
    print(C.dim("  Run `ollama serve` first, then pull models (see comments above)"))
    print("")

    // Probe which models are actually pulled
    print(C.bold("Availability probe:"))
    let available = ollamaAvailabilityProbe()
    let liveTargets = ollamaTargets().filter { available[$0.modelID] == true }

    guard !liveTargets.isEmpty else {
        print(C.err("\n  No Ollama models available. Run: ollama pull tinyllama qwen:0.5b gemma:2b phi phi3:mini"))
        return []
    }

    print("\n\(C.bold("\(liveTargets.count)/\(ollamaTargets().count) models live — running benchmarks:"))")
    print(C.dim("  NOTE: times are macOS CPU via Ollama. On-device MLX via ANE is ~3–8× faster."))
    print(C.dim("  Cold-start = first request after model load. Warm = subsequent requests."))
    var all: [RunResult] = []
    let localTimeout: TimeInterval = 300  // CPU inference can be slow on macOS

    for t in liveTargets {
        print("\n\(C.bold(t.displayName)) \(C.gray("[\(t.modelID)]")) \(C.dim(t.notes))")

        // Cold start — first prompt loads the model into memory
        print(C.dim("  [cold-start] sending first request to load model …"))
        let coldStart = runOnce(target: t, prompt: PROMPTS_SHORT[0], timeoutSeconds: localTimeout)
        let coldSt = coldStart.success
            ? C.warn("cold: \(coldStart.totalMs)ms")
            : C.err("cold load FAILED: \(coldStart.errorMessage.prefix(60))")
        print("  \(coldSt)")

        if coldStart.success {
            Thread.sleep(forTimeInterval: 0.5)
            // Warm prompts — baseline latency
            all += runBench(target: t, prompts: PROMPTS_SHORT, iterations: 2, label: "local-short", timeoutSeconds: localTimeout)
            Thread.sleep(forTimeInterval: 0.5)
            // Quality prompts — where tiny models diverge most
            all += runBench(target: t, prompts: PROMPTS_TINY_QUALITY, iterations: 1, label: "local-quality", timeoutSeconds: localTimeout)
        } else {
            print(C.err("  Skipping warm benchmarks — model failed to load"))
        }
        Thread.sleep(forTimeInterval: 2.0)
    }

    // Print size/speed/quality summary
    print("\n" + C.bold("── Bundle Candidate Summary ──"))
    let sizeMap: [String: String] = [
        "qwen:0.5b": "394MB", "tinyllama": "640MB", "stablelm2": "1.1GB",
        "phi": "1.6GB", "gemma:2b": "1.7GB", "openchat": "2.0GB", "phi3:mini": "2.2GB"
    ]
    let byModel = Dictionary(grouping: all.filter { $0.success }, by: { $0.modelID })
    print("  \(C.bold("Model".padding(toLength: 22, withPad: " ", startingAt: 0))) \("Size".padding(toLength: 7, withPad: " ", startingAt: 0)) \("Avg ms".padding(toLength: 9, withPad: " ", startingAt: 0)) \("t/s")")
    for t in liveTargets {
        guard let runs = byModel[t.modelID], !runs.isEmpty else { continue }
        let avg = runs.map { $0.totalMs }.reduce(0, +) / runs.count
        let tps = runs.map { $0.tokPerSecEst }.reduce(0, +) / Double(runs.count)
        let sz  = sizeMap[t.modelID] ?? "?"
        print("  \(t.displayName.padding(toLength: 22, withPad: " ", startingAt: 0)) \(sz.padding(toLength: 7, withPad: " ", startingAt: 0)) \("\(avg)ms".padding(toLength: 9, withPad: " ", startingAt: 0)) \(String(format: "%.1f t/s", tps))")
    }

    return all
}

func suiteContextFilterImpact() -> [RunResult] {
    banner("Suite 7 · Optimization Impact — Context Filtering Simulation")
    print(C.dim("  Compares full 2000-token context vs filtered ~200-token context"))
    print(C.dim("  Simulates AIManager+ContextFiltering semantic truncation benefit"))

    let t = zazuTargets()[0]
    let full   = contextScalePrompt(targetTokens: 2000)
    let filler = "The quick brown fox jumps over the lazy dog. " // ~10 tokens
    let relevantOnly = Prompt(
        label: "ctx-filtered",
        text: "\(filler)\n\nGiven the above text, how many times does the word 'fox' appear? Just the integer."
    )

    var all: [RunResult] = []
    print("\n\(C.bold("Full context (~2000 tokens):"))")
    all += runBench(target: t, prompts: [full], iterations: 2, label: "ctx-full")
    Thread.sleep(forTimeInterval: 2.0)
    print("\(C.bold("Filtered context (~50 tokens):"))")
    all += runBench(target: t, prompts: [relevantOnly], iterations: 2, label: "ctx-filtered")

    if let fullR = all.first(where: { $0.promptLabel == "ctx-2000t" }),
       let filtR = all.first(where: { $0.promptLabel == "ctx-filtered" }),
       fullR.success, filtR.success {
        let saving = fullR.totalMs - filtR.totalMs
        let pct = saving > 0 ? Int(Double(saving) / Double(fullR.totalMs) * 100) : 0
        print("\n  \(C.cyan("Filtering saved:")) \(saving)ms (\(pct)% faster) on \(t.displayName)")
    }
    return all
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Device capability matrix (static, documented)
// ─────────────────────────────────────────────────────────────────────────────

func printDeviceMatrix() {
    banner("Device Capability Matrix (Static Reference)")
    let cols = ["Device", "Chip", "RAM", "Phi-3.5 mini", "7B 4-bit", "NE"]
    let rows: [[String]] = [
        ["iPhone 12 mini",      "A14 Bionic", "4GB", "OK",  "No",  "11 TOPS"],
        ["iPhone 12 Pro Max",   "A14 Bionic", "6GB", "OK",  "OK",  "11 TOPS"],
        ["iPhone 13 Pro Max",   "A15 Bionic", "6GB", "OK",  "OK",  "15.8 TOPS"],
        ["iPhone 14 Pro",       "A16 Bionic", "6GB", "OK",  "OK",  "17 TOPS"],
        ["iPhone 15 Pro",       "A17 Pro",    "8GB", "OK",  "OK",  "35 TOPS"],
        ["iPad Air 4th (4GB)",  "A14 Bionic", "4GB", "OK",  "No",  "11 TOPS"],
        ["iPad Pro 11\" 2nd",   "A12Z",       "6GB", "OK",  "OK",  "8 TOPS"],
        ["iPad Pro 11\" 3rd",   "M1",         "8GB", "OK",  "OK",  "11 TOPS"],
    ]
    let widths = [22, 12, 5, 14, 9, 12]
    let hdr = zip(cols, widths).map { c, w in c.padding(toLength: w, withPad: " ", startingAt: 0) }.joined(separator: " │ ")
    print("  " + C.bold(hdr))
    print("  " + String(repeating: "─", count: hdr.count))
    for row in rows {
        let line = zip(row, widths).map { c, w in
            let padded = c.padding(toLength: w, withPad: " ", startingAt: 0)
            if c == "OK"  { return C.ok(padded) }
            if c == "No"  { return C.warn(padded) }
            return padded
        }.joined(separator: " │ ")
        print("  " + line)
    }
    print("")
    print(C.dim("  Phi-3.5 mini 4-bit:  requires iOS 18+, ≥4GB RAM, ~2.2GB active memory"))
    print(C.dim("  7B 4-bit (e.g. Llama-3-8B-4bit):  requires ≥6GB RAM, ~4.5-5GB active"))
    print(C.dim("  Cold start on A14: ~8-15s | A15: ~5-10s | A17 Pro: ~2-4s"))
    print(C.dim("  Warm TTFT on A14:  ~400-800ms | A17 Pro: ~80-200ms"))
    print(C.dim("  Token throughput:  A14 ~15-25 t/s | A15 ~25-40 t/s | A17 Pro ~50-80 t/s"))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Summary table + stats
// ─────────────────────────────────────────────────────────────────────────────

func printSummaryTable(_ results: [RunResult]) {
    banner("Results Summary")
    guard !results.isEmpty else { print(C.warn("  No results collected.")); return }

    // Group by model
    var byModel: [String: [RunResult]] = [:]
    for r in results { byModel[r.modelID, default: []].append(r) }

    let header = ["Model", "Succ%", "Avg ms", "P50 ms", "P95 ms", "t/s (avg)", "Prompts"]
    let widths  = [28, 7, 8, 8, 8, 10, 7]
    let hdr = zip(header, widths).map { c, w in c.padding(toLength: w, withPad: " ", startingAt: 0) }.joined(separator: " │ ")
    print("  " + C.bold(hdr))
    print("  " + String(repeating: "─", count: hdr.count))

    for (modelID, runs) in byModel.sorted(by: { $0.key < $1.key }) {
        let n      = runs.count
        let succ   = runs.filter { $0.success }.count
        let succPct = Int(Double(succ) / Double(n) * 100)
        let times  = runs.filter { $0.success }.map { $0.totalMs }.sorted()
        let avg    = times.isEmpty ? 0 : times.reduce(0,+) / times.count
        let p50    = times.isEmpty ? 0 : times[times.count / 2]
        let p95idx = max(0, Int(Double(times.count) * 0.95) - 1)
        let p95    = times.isEmpty ? 0 : times[p95idx]
        let tps    = runs.filter { $0.success }.map { $0.tokPerSecEst }
        let avgTps = tps.isEmpty ? 0.0 : tps.reduce(0,+) / Double(tps.count)

        let name = (byModel[modelID]?.first?.displayName ?? modelID)
            .padding(toLength: 28, withPad: " ", startingAt: 0)
        let sp   = "\(succPct)%".padding(toLength: 7, withPad: " ", startingAt: 0)
        let am   = "\(avg)".padding(toLength: 8, withPad: " ", startingAt: 0)
        let pm   = "\(p50)".padding(toLength: 8, withPad: " ", startingAt: 0)
        let p9   = "\(p95)".padding(toLength: 8, withPad: " ", startingAt: 0)
        let ts   = String(format: "%.1f", avgTps).padding(toLength: 10, withPad: " ", startingAt: 0)
        let cnt  = "\(n)".padding(toLength: 7, withPad: " ", startingAt: 0)

        let color: (String) -> String = succPct >= 90 ? C.ok : succPct >= 50 ? C.warn : C.err
        print("  " + color("\(name) │ \(sp) │ \(am) │ \(pm) │ \(p9) │ \(ts) │ \(cnt)"))
    }
}

func computeSummaryStats(_ results: [RunResult]) -> [String: String] {
    let succ = results.filter { $0.success }
    let succRate = results.isEmpty ? 0.0 : Double(succ.count) / Double(results.count) * 100
    let avgMs = succ.isEmpty ? 0 : succ.map { $0.totalMs }.reduce(0,+) / succ.count
    let models = Set(results.map { $0.modelID }).count
    let bestModel = Dictionary(grouping: succ, by: { $0.modelID })
        .mapValues { $0.map { $0.totalMs }.reduce(0,+) / $0.count }
        .min(by: { $0.value < $1.value })
    return [
        "totalRuns":    "\(results.count)",
        "successRate":  String(format: "%.1f%%", succRate),
        "avgLatencyMs": "\(avgMs)",
        "modelsTestedCount": "\(models)",
        "fastestModel": bestModel.map { "\($0.key) (\($0.value)ms)" } ?? "N/A",
    ]
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Report persistence
// ─────────────────────────────────────────────────────────────────────────────

func saveJSONReport(_ report: BenchmarkReport) {
    let fm = FileManager.default
    let dir = Config.resultsDir
    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    let fname = "\(dir)/benchmark_\(report.runID).json"
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(report) {
        fm.createFile(atPath: fname, contents: data)
        print(C.dim("  JSON saved: \(fname)"))
    }
}

func appendMarkdownSummary(_ report: BenchmarkReport) {
    let path = Config.summaryPath
    let fm = FileManager.default
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"

    let byModel = Dictionary(grouping: report.results.filter { $0.success }, by: { $0.displayName })
    var table = "| Model | Succ% | Avg ms | t/s | Prompts |\n|---|---|---|---|---|\n"
    let allModels = Dictionary(grouping: report.results, by: { $0.displayName })
    for (name, runs) in allModels.sorted(by: { $0.key < $1.key }) {
        let n = runs.count
        let s = runs.filter { $0.success }.count
        let sp = Int(Double(s) / Double(n) * 100)
        let times = runs.filter { $0.success }.map { $0.totalMs }
        let avg = times.isEmpty ? 0 : times.reduce(0,+) / times.count
        let tpsSum: Double = byModel[name]?.map { $0.tokPerSecEst }.reduce(0, +) ?? 0
        let tpsCount = byModel[name]?.count ?? 1
        let tps: Double = tpsCount > 0 ? tpsSum / Double(tpsCount) : 0
        table += "| \(name) | \(sp)% | \(avg) | \(String(format: "%.1f", tps)) | \(n) |\n"
    }

    let stats = report.summaryStats
    let section = """

---

## Benchmark Run — \(report.startedAt)

**Suite:** \(report.suiteName)
**Host:** \(report.hostMachine)
**Run ID:** \(report.runID)
**Total runs:** \(stats["totalRuns"] ?? "?") — Success rate: \(stats["successRate"] ?? "?")
**Avg latency:** \(stats["avgLatencyMs"] ?? "?")ms — Fastest model: \(stats["fastestModel"] ?? "N/A")
**Models tested:** \(stats["modelsTestedCount"] ?? "?")

\(table)
"""

    if fm.fileExists(atPath: path),
       let existing = try? String(contentsOfFile: path, encoding: .utf8) {
        let updated = "# PrivateViewer AI Benchmark Results\n" + section + existing.replacingOccurrences(of: "# PrivateViewer AI Benchmark Results\n", with: "")
        try? updated.write(toFile: path, atomically: true, encoding: .utf8)
    } else {
        let fresh = "# PrivateViewer AI Benchmark Results\n" + section
        try? fresh.write(toFile: path, atomically: true, encoding: .utf8)
    }
    print(C.dim("  Markdown appended: \(path)"))
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Entry point
// ─────────────────────────────────────────────────────────────────────────────

let args = CommandLine.arguments
let suiteArg = args.first(where: { $0.hasPrefix("--suite") }).flatMap { a -> String? in
    let parts = a.components(separatedBy: "=")
    if parts.count == 2 { return parts[1] }
    if let idx = args.firstIndex(of: "--suite"), idx + 1 < args.count { return args[idx+1] }
    return nil
} ?? "full"
let jsonOnly = args.contains("--json-only")

let runID = {
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmss"
    return df.string(from: Date())
}()

let iso = ISO8601DateFormatter()
let startTime = Date()

// Print header
if !jsonOnly {
    print(C.hdr("\n══ MulberryBench ══ open, run-it-yourself AI benchmark"))
    print(C.dim("   no account · local runs make no network calls · cloud is your own key"))
    print(C.hdr("   Run ID: \(runID)"))

    print("\n\(C.bold("Suite:")) \(suiteArg)")
    print("\(C.bold("OpenRouter key:")) \(Config.zazuKey.isEmpty ? C.dim("not set — BYOK: export OPENROUTER_KEY") : C.ok("set (…\(String(Config.zazuKey.suffix(6))))"))")
    print("\(C.bold("OpenAI key:"))    \(Config.openAIKey != nil    ? C.ok("set") : C.dim("not set"))")
    print("\(C.bold("Anthropic key:")) \(Config.anthropicKey != nil ? C.ok("set") : C.dim("not set"))")
    print("\(C.bold("Mistral key:"))   \(Config.mistralKey != nil   ? C.ok("set") : C.dim("not set"))")

    printDeviceMatrix()
}

var allResults: [RunResult] = []

switch suiteArg {
case "zazu":
    allResults += suiteZazuPool()
case "api":
    allResults += suiteAPILatency()
case "code":
    allResults += suiteCodeThroughput()
case "context":
    allResults += suiteContextScaling()
case "rotation":
    allResults += suiteFreeOrchRotation()
case "concurrency":
    allResults += suiteConcurrency()
case "optimize":
    allResults += suiteContextFilterImpact()
case "alt":
    allResults += suiteAltModels()
case "ollama":
    allResults += suiteOllamaLocal()
case "full":
    allResults += suiteZazuPool()
    allResults += suiteAPILatency()
    allResults += suiteCodeThroughput()
    allResults += suiteContextScaling()
    allResults += suiteContextFilterImpact()
default:
    print(C.err("Unknown suite: \(suiteArg). Use: zazu|api|code|context|rotation|concurrency|optimize|alt|ollama|full"))
    exit(1)
}

let stats = computeSummaryStats(allResults)
if !jsonOnly { printSummaryTable(allResults) }

let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
let swiftVer = ProcessInfo.processInfo.environment["SWIFT_VERSION"] ?? "unknown"

var report = BenchmarkReport(
    runID:        runID,
    startedAt:    iso.string(from: startTime),
    finishedAt:   iso.string(from: Date()),
    suiteName:    suiteArg,
    hostMachine:  hostName,
    swiftVersion: swiftVer,
    results:      allResults,
    summaryStats: stats
)
report.summaryStats = stats

if jsonOnly {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(report), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
} else {
    saveJSONReport(report)
    appendMarkdownSummary(report)
    let duration = Int(Date().timeIntervalSince(startTime))
    print("\n\(C.hdr("Done in \(duration)s"))\n")
}
