// cost_audit.swift: developer check that SturtBar's cost estimates match an independent reprice.
//
// Usage: swift Scripts/cost_audit.swift [--codex] [--days N] [--state PATH]   (or `make cost-audit`)
//
// Reads token counts from local logs (never prompt text), prices them with the rate table below
// (copied from the providers' pricing pages, not from SturtBar's code), and diffs the per-model
// totals against SturtBar's last saved snapshot. Read-only, no network, prints aggregates only.
// Exits 1 when a model differs by more than a cent (or 0.1%) or has no price here.

import Foundation

struct Rates {
    let input: Double
    let output: Double
    let cacheWrite: Double
    let cacheRead: Double
    var longContext: (threshold: Int, input: Double, output: Double, cacheRead: Double)?
    var fastMultiplier: Double?
}

/// Per million tokens. Claude: Anthropic pricing page. Codex: OpenAI pricing page (Sep 2026).
let claudeRates: [String: Rates] = [
    "claude-fable-5-1": Rates(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 0.25),
    "claude-fable-5": Rates(input: 10, output: 50, cacheWrite: 12.5, cacheRead: 1),
    "claude-opus-5-5": Rates(input: 4, output: 20, cacheWrite: 5, cacheRead: 0.2, fastMultiplier: 2),
    "claude-opus-5": Rates(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5, fastMultiplier: 2),
    "claude-opus-4-8": Rates(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
    "claude-opus-4-7": Rates(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
    "claude-opus-4-6": Rates(input: 5, output: 25, cacheWrite: 6.25, cacheRead: 0.5),
    "claude-sonnet-5": Rates(input: 2, output: 10, cacheWrite: 2.5, cacheRead: 0.2),
    "claude-sonnet-4-6": Rates(input: 3, output: 15, cacheWrite: 3.75, cacheRead: 0.3),
    "claude-haiku-4-5": Rates(input: 1, output: 5, cacheWrite: 1.25, cacheRead: 0.1),
]

let codexRates: [String: Rates] = [
    "gpt-6-astra": Rates(input: 10, output: 50, cacheWrite: 0, cacheRead: 1, longContext: (272_000, 20, 75, 2)),
    "gpt-5.6-sol": Rates(input: 4, output: 20, cacheWrite: 0, cacheRead: 0.4, longContext: (272_000, 8, 30, 0.8)),
    "gpt-5.6-terra": Rates(input: 2, output: 12, cacheWrite: 0, cacheRead: 0.2, longContext: (272_000, 4, 18, 0.4)),
    "gpt-5.6-luna": Rates(input: 0.2, output: 1.2, cacheWrite: 0, cacheRead: 0.02, longContext: (272_000, 0.4, 1.8, 0.04)),
    "gpt-5.5": Rates(input: 5, output: 30, cacheWrite: 0, cacheRead: 0.5, longContext: (272_000, 10, 45, 1)),
    "gpt-5.3-codex": Rates(input: 1.75, output: 14, cacheWrite: 0, cacheRead: 0.175),
]

/// No public price anywhere; SturtBar leaves them unpriced too, so they are reported, not failed.
let knownUnpriced: Set<String> = ["codex-auto-review", "gpt-reserve"]

struct Tally {
    var tokens = 0
    var cost = 0.0
    var unpricedTokens = 0
}

// MARK: - Arguments and window

var includeCodex = false
var days = 30
var statePath: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--codex": includeCodex = true
    case "--days": days = min(30, max(1, Int(arguments.next() ?? "") ?? 30))
    case "--state": statePath = arguments.next()
    default:
        FileHandle.standardError.write(Data("usage: cost_audit.swift [--codex] [--days N] [--state PATH]\n".utf8))
        exit(2)
    }
}

let calendar = Calendar.current
let windowStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
let dayFormatter = DateFormatter()
dayFormatter.locale = Locale(identifier: "en_US_POSIX")
dayFormatter.dateFormat = "yyyy-MM-dd"
let isoFormatter = ISO8601DateFormatter()
isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
let isoFallback = ISO8601DateFormatter()

/// Only rows the app's last scan could have seen: inside the window and no later than its snapshot.
func dayKey(_ timestamp: String, until: Date) -> String? {
    guard let date = isoFormatter.date(from: timestamp) ?? isoFallback.date(from: timestamp),
          date >= windowStart, date <= until
    else { return nil }
    return dayFormatter.string(from: date)
}

// MARK: - Reading logs

func jsonlFiles(under roots: [URL]) -> [URL] {
    roots.flatMap { root -> [URL] in
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return false }
            return (values.contentModificationDate ?? .distantPast) >= windowStart.addingTimeInterval(-86400)
        }
    }
}

func forEachJSONLine(in url: URL, containing marker: String, _ body: ([String: Any]) -> Void) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }
    let needle = Data(marker.utf8)
    var buffer = Data()
    func emit(_ line: Data) {
        guard line.range(of: needle) != nil,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        else { return }
        body(object)
    }
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            emit(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
    }
    if !buffer.isEmpty { emit(buffer) }
}

func count(_ value: Any?) -> Int {
    (value as? NSNumber).map { max(0, $0.intValue) } ?? 0
}

// MARK: - Claude

func claudeRoots() -> [URL] {
    if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
        return env.split(separator: ",").map { part in
            let url = URL(fileURLWithPath: part.trimmingCharacters(in: .whitespaces))
            return url.lastPathComponent == "projects" ? url : url.appendingPathComponent("projects")
        }
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [home.appendingPathComponent(".config/claude/projects"), home.appendingPathComponent(".claude/projects")]
}

func claudeModelKey(_ raw: String) -> String {
    var model = raw.trimmingCharacters(in: .whitespaces)
    if let tag = model.range(of: #"\[\d+[a-z]\]$"#, options: .regularExpression) { model.removeSubrange(tag) }
    if model.hasPrefix("anthropic.") { model.removeFirst("anthropic.".count) }
    if let date = model.range(of: #"-\d{8}$"#, options: .regularExpression),
       claudeRates[String(model[..<date.lowerBound])] != nil
    {
        model = String(model[..<date.lowerBound])
    }
    return model
}

func auditClaude(until: Date) -> [String: Tally] {
    var latest: [String: (model: String, day: String, tokens: Int, cost: Double?)] = [:]
    var anonymous: [(model: String, day: String, tokens: Int, cost: Double?)] = []
    for file in jsonlFiles(under: claudeRoots()) {
        forEachJSONLine(in: file, containing: #""usage""#) { object in
            guard object["type"] as? String == "assistant",
                  let timestamp = object["timestamp"] as? String,
                  let day = dayKey(timestamp, until: until),
                  let message = object["message"] as? [String: Any],
                  let rawModel = message["model"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { return }
            let messageID = message["id"] as? String
            let requestID = object["requestId"] as? String
            if rawModel.contains("@") || (messageID ?? "").contains("_vrtx_") || (requestID ?? "").contains("_vrtx_") {
                return
            }
            let input = count(usage["input_tokens"])
            let write = count(usage["cache_creation_input_tokens"])
            let read = count(usage["cache_read_input_tokens"])
            let output = count(usage["output_tokens"])
            guard input + write + read + output > 0 else { return }
            let preliminary = message["stop_reason"] is NSNull && input > 0 && output == 0
                && usage["cache_read_input_tokens"] == nil && usage["cache_creation_input_tokens"] == nil
            if preliminary { return }
            let oneHourWrite = min(write, count((usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"]))
            let model = claudeModelKey(rawModel)
            let isFast = usage["speed"] as? String == "fast"
            var cost: Double?
            if let rates = claudeRates[model], !isFast || rates.fastMultiplier != nil {
                let base = Double(input) * rates.input + Double(read) * rates.cacheRead
                    + Double(write - oneHourWrite) * rates.cacheWrite + Double(oneHourWrite) * rates.input * 2
                    + Double(output) * rates.output
                cost = base / 1_000_000 * (isFast ? rates.fastMultiplier ?? 1 : 1)
            }
            let row = (model, day, input + write + read + output, cost)
            let session = object["sessionId"] as? String
            if let messageID, let requestID {
                latest["r|\(messageID)|\(requestID)"] = row
            } else if let messageID, let session {
                latest["s|\(session)|\(messageID)"] = row
            } else {
                anonymous.append(row)
            }
        }
    }
    var tallies: [String: Tally] = [:]
    for row in Array(latest.values) + anonymous {
        tallies[row.model, default: Tally()].tokens += row.tokens
        if let cost = row.cost {
            tallies[row.model, default: Tally()].cost += cost
        } else {
            tallies[row.model, default: Tally()].unpricedTokens += row.tokens
        }
    }
    return tallies
}

// MARK: - Codex

func codexModelKey(_ raw: String) -> String {
    var model = raw.trimmingCharacters(in: .whitespaces)
    if model.hasPrefix("openai/") { model.removeFirst("openai/".count) }
    if model == "gpt-5.6" { return "gpt-5.6-sol" }
    if let date = model.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression),
       codexRates[String(model[..<date.lowerBound])] != nil
    {
        model = String(model[..<date.lowerBound])
    }
    return model
}

func auditCodex(until: Date) -> [String: Tally] {
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    var tallies: [String: Tally] = [:]
    for file in jsonlFiles(under: [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]) {
        var currentModel: String?
        var previous: (input: Int, cached: Int, output: Int)?
        forEachJSONLine(in: file, containing: "t") { object in
            let payload = object["payload"] as? [String: Any]
            if object["type"] as? String == "turn_context" {
                let context = payload ?? object
                if let model = (context["model"] as? String) ?? (context["model_name"] as? String), !model.isEmpty {
                    currentModel = model
                }
                return
            }
            guard object["type"] as? String == "event_msg",
                  payload?["type"] as? String == "token_count",
                  let info = payload?["info"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String
            else { return }
            func totals(_ value: Any?) -> (input: Int, cached: Int, output: Int)? {
                guard let usage = value as? [String: Any] else { return nil }
                return (count(usage["input_tokens"]),
                        max(count(usage["cached_input_tokens"]), count(usage["cache_read_input_tokens"])),
                        count(usage["output_tokens"]))
            }
            var turn: (input: Int, cached: Int, output: Int)
            if let last = totals(info["last_token_usage"]) {
                turn = last
                if let total = totals(info["total_token_usage"]) { previous = total }
            } else if let total = totals(info["total_token_usage"]) {
                let base = previous ?? (0, 0, 0)
                turn = (max(0, total.input - base.input), max(0, total.cached - base.cached), max(0, total.output - base.output))
                previous = total
            } else {
                return
            }
            guard dayKey(timestamp, until: until) != nil, turn.input + turn.cached + turn.output > 0 else { return }
            let recordModel = (info["model"] as? String) ?? (info["model_name"] as? String) ?? (payload?["model"] as? String)
            let model = codexModelKey(currentModel ?? recordModel ?? "gpt-5")
            let cached = min(turn.cached, turn.input)
            let tokens = turn.input + turn.output
            tallies[model, default: Tally()].tokens += tokens
            guard let rates = codexRates[model] else {
                tallies[model, default: Tally()].unpricedTokens += tokens
                return
            }
            let long = rates.longContext.flatMap { turn.input > $0.threshold ? $0 : nil }
            let cost = Double(turn.input - cached) * (long?.input ?? rates.input)
                + Double(cached) * (long?.cacheRead ?? rates.cacheRead)
                + Double(turn.output) * (long?.output ?? rates.output)
            tallies[model, default: Tally()].cost += cost / 1_000_000
        }
    }
    return tallies
}

// MARK: - SturtBar snapshot

func appTallies(key: String, modelKey: (String) -> String) -> (tallies: [String: Tally], updatedAt: Date) {
    let state = statePath.map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SturtBar/state.json")
    guard let data = try? Data(contentsOf: state),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let snapshot = root[key] as? [String: Any],
          let daily = snapshot["daily"] as? [[String: Any]]
    else { return ([:], Date()) }
    let updatedAt = (snapshot["updatedAt"] as? NSNumber).map { Date(timeIntervalSinceReferenceDate: $0.doubleValue) }
    let firstDay = dayFormatter.string(from: windowStart)
    var tallies: [String: Tally] = [:]
    for entry in daily where (entry["date"] as? String ?? "") >= firstDay {
        for breakdown in entry["modelBreakdowns"] as? [[String: Any]] ?? [] {
            guard let name = breakdown["modelName"] as? String else { continue }
            let model = modelKey(name)
            tallies[model, default: Tally()].tokens += count(breakdown["totalTokens"])
            tallies[model, default: Tally()].cost += (breakdown["costUSD"] as? NSNumber)?.doubleValue ?? 0
            tallies[model, default: Tally()].unpricedTokens += count(breakdown["unpricedTokens"])
        }
    }
    return (tallies, updatedAt ?? Date())
}

// MARK: - Report

func money(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

func report(title: String, audit: [String: Tally], app: [String: Tally]) -> Bool {
    print("\n\(title), last \(days) days up to the app's last scan (app snapshot vs independent reprice)")
    print("model".padding(toLength: 28, withPad: " ", startingAt: 0) + "     app cost    audit cost   tokens (app/audit)")
    var clean = true
    for model in Set(audit.keys).union(app.keys).sorted() {
        let ours = audit[model] ?? Tally()
        let theirs = app[model] ?? Tally()
        let expectedUnpriced = knownUnpriced.contains(model)
        let tolerance = max(0.01, ours.cost * 0.001)
        let mismatch = abs(ours.cost - theirs.cost) > tolerance || (ours.unpricedTokens > 0 && !expectedUnpriced)
        clean = clean && !mismatch
        let flag = expectedUnpriced ? "  no public price" : (mismatch ? "  MISMATCH" : "")
        print(
            model.padding(toLength: 28, withPad: " ", startingAt: 0)
                + money(theirs.cost).leftPad(13) + money(ours.cost).leftPad(14)
                + "   \(theirs.tokens)/\(ours.tokens)" + flag)
    }
    let appTotal = app.values.reduce(0) { $0 + $1.cost }
    let auditTotal = audit.values.reduce(0) { $0 + $1.cost }
    print("total".padding(toLength: 28, withPad: " ", startingAt: 0) + money(appTotal).leftPad(13) + money(auditTotal).leftPad(14))
    return clean
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

let claudeApp = appTallies(key: "cost", modelKey: claudeModelKey)
var clean = report(title: "Claude", audit: auditClaude(until: claudeApp.updatedAt), app: claudeApp.tallies)
if includeCodex {
    let codexApp = appTallies(key: "codexCost", modelKey: codexModelKey)
    clean = report(title: "Codex", audit: auditCodex(until: codexApp.updatedAt), app: codexApp.tallies) && clean
}
print(clean ? "\nOK: every priced model matches." : "\nCheck the flagged models before releasing.")
exit(clean ? 0 : 1)
