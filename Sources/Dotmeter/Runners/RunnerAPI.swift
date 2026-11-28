import Foundation

/// A program that serves models on this Mac.
enum RunnerKind: String, CaseIterable {
    case ollama, lmStudio, llamaCpp, mlx

    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .llamaCpp: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }

    var symbol: String {
        switch self {
        case .ollama: return "shippingbox.fill"
        case .lmStudio: return "rectangle.3.group.fill"
        case .llamaCpp: return "terminal.fill"
        case .mlx: return "cube.fill"
        }
    }

    var rgb: RGB {
        switch self {
        case .ollama: return PX.teal
        case .lmStudio: return PX.purple
        case .llamaCpp: return PX.orange
        case .mlx: return PX.blue
        }
    }
}

/// One model as a runner describes it: loaded in memory, or sitting on disk.
struct RunnerModel: Equatable, Identifiable {
    /// Where a loaded model's size comes from, since only some runners say what a model holds.
    enum SizeSource: Equatable { case reported, file, process }

    var runner: RunnerKind
    /// What the runner calls it, and what a request has to name.
    var name: String
    var title: String
    /// "70.6B"
    var parameters: String?
    /// "Q4_K_M"
    var quantization: String?
    /// Loaded: the bytes it holds, as far as the runner says. Installed: the bytes on disk.
    var size: UInt64?
    var sizeSource = SizeSource.reported
    /// Of `size`, what sits on the graphics chip. Only Ollama says.
    var onGraphics: UInt64?
    /// The context it was loaded with, in tokens.
    var context: Int?
    /// When the runner will unload it if nothing asks for it again.
    var expires: Date?
    /// False for an embedding model, which cannot be timed with a prompt.
    var generates = true

    var id: String { runner.rawValue + "|" + name }
}

/// What one runner's API said at one moment.
struct RunnerReading: Equatable {
    var kind: RunnerKind
    var base: URL
    var answered = false
    var version: String?
    var loaded: [RunnerModel] = []
    /// Nil when the list was not asked for this time: the one before still stands.
    var installed: [RunnerModel]?
    /// Why it answered but said nothing useful: it wants a token, say.
    var note: String?
    /// Which of LM Studio's three APIs answered: "v1", "v0" or "openai".
    var variant: String?

    var port: Int { base.port ?? 80 }
}

struct RunnerSpeedResult: Equatable {
    var tokensPerSecond: Double
    /// Seconds until the first token came back.
    var firstToken: Double?
    var tokens: Int

    /// "48.5 tokens/s"
    var rateText: String {
        tokensPerSecond >= 99.95 ? "\(Int(tokensPerSecond.rounded())) tokens/s" : String(format: "%.1f tokens/s", tokensPerSecond)
    }

    /// "250 ms", "1.4 s"
    var firstTokenText: String? {
        guard let firstToken else { return nil }
        if firstToken < 0.9995 { return "\(Int((firstToken * 1000).rounded())) ms" }
        return firstToken < 9.95 ? String(format: "%.1f s", firstToken) : "\(Int(firstToken.rounded())) s"
    }

    /// "48.5 tokens/s · first token in 250 ms"
    var text: String { firstTokenText.map { "\(rateText) · first token in \($0)" } ?? rateText }
}

// MARK: - Reading JSON whose shape is not promised

/// A runner's answer, read one field at a time. Every field may be missing or of another type, and an unknown
/// shape reads as nothing, because these APIs change between versions and none of them is ours.
struct JSONValue {
    var raw: Any?

    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    init(data: Data) { self.init(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) }

    init(text: String) { self.init(data: Data(text.utf8)) }

    subscript(key: String) -> JSONValue { JSONValue((raw as? [String: Any])?[key]) }

    var exists: Bool { raw != nil }
    /// Nil when the value is not a list at all, so "no list" and "an empty list" can be told apart.
    var list: [JSONValue]? { (raw as? [Any])?.map(JSONValue.init) }
    var array: [JSONValue] { list ?? [] }
    var string: String? { (raw as? String).flatMap { $0.isEmpty ? nil : $0 } }
    var number: Double? {
        guard !(raw is String), let number = raw as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    var bytes: UInt64? {
        guard let number, number >= 0, number < 1e18 else { return nil }
        return (raw as? NSNumber)?.uint64Value
    }
    var int: Int? {
        guard let number, abs(number) < 1e15 else { return nil }
        return Int(number)
    }
    var bool: Bool? { raw as? Bool }
}

// MARK: - Decoding each runner's answers

enum RunnerDecode {
    // Ollama

    static func ollamaVersion(_ json: JSONValue) -> String? { json["version"].string }

    /// `GET /api/ps`: the models in memory.
    static func ollamaLoaded(_ json: JSONValue) -> [RunnerModel]? {
        guard let entries = json["models"].list else { return nil }
        return entries.compactMap { entry in
            guard var model = ollamaModel(entry) else { return nil }
            model.onGraphics = entry["size_vram"].bytes
            model.context = entry["context_length"].int ?? entry["details"]["context_length"].int
            model.expires = date(entry["expires_at"].string)
            return model
        }
    }

    /// `GET /api/tags`: the models on disk.
    static func ollamaInstalled(_ json: JSONValue) -> [RunnerModel]? {
        guard let entries = json["models"].list else { return nil }
        return entries.compactMap { entry in
            guard var model = ollamaModel(entry) else { return nil }
            model.sizeSource = .file
            return model
        }
    }

    private static func ollamaModel(_ entry: JSONValue) -> RunnerModel? {
        guard let name = entry["name"].string ?? entry["model"].string else { return nil }
        let details = entry["details"]
        let family = details["family"].string?.lowercased() ?? ""
        return RunnerModel(
            runner: .ollama, name: name, title: name,
            parameters: details["parameter_size"].string, quantization: details["quantization_level"].string,
            size: entry["size"].bytes,
            // The embedding families Ollama ships; anything else is taken to answer a prompt.
            generates: !(family.contains("bert") || name.lowercased().contains("embed"))
        )
    }

    /// The last object of `POST /api/generate`. Its durations are nanoseconds. Time to the first token is the
    /// runner's own: loading plus reading the prompt. `wallFirst` stands in when it does not say.
    static func ollamaSpeed(_ json: JSONValue, wallFirst: Double?) -> RunnerSpeedResult? {
        guard let count = json["eval_count"].int, let duration = json["eval_duration"].number,
              let rate = RunnerMath.tokensPerSecond(tokens: count, nanoseconds: duration) else { return nil }
        var first = wallFirst
        if let prompt = json["prompt_eval_duration"].number { first = (prompt + (json["load_duration"].number ?? 0)) / 1e9 }
        return RunnerSpeedResult(tokensPerSecond: rate, firstToken: first, tokens: count)
    }

    // LM Studio

    /// `GET /api/v1/models` (LM Studio 0.4 and later): every model on disk, each with the instances in memory.
    static func lmStudioV1(_ json: JSONValue) -> (loaded: [RunnerModel], installed: [RunnerModel])? {
        guard let entries = json["models"].list else { return nil }
        var loaded: [RunnerModel] = [], installed: [RunnerModel] = []
        for entry in entries {
            guard let key = entry["key"].string else { continue }
            let model = RunnerModel(
                runner: .lmStudio, name: key, title: entry["display_name"].string ?? key,
                parameters: entry["params_string"].string, quantization: entry["quantization"]["name"].string,
                size: entry["size_bytes"].bytes, sizeSource: .file,
                generates: !(entry["type"].string ?? "llm").hasPrefix("embedding")
            )
            installed.append(model)
            let instances = entry["loaded_instances"].array
            for instance in instances {
                var copy = model
                // A request names the instance, which is the key unless the same model is loaded twice.
                copy.name = instance["id"].string ?? key
                if instances.count > 1, copy.name != key { copy.title = "\(model.title) (\(copy.name))" }
                copy.context = instance["config"]["context_length"].int
                loaded.append(copy)
            }
        }
        return (loaded, installed)
    }

    /// `GET /api/v0/models` (LM Studio 0.3.6 and later): the same list with a `state`, and no sizes.
    static func lmStudioV0(_ json: JSONValue) -> (loaded: [RunnerModel], installed: [RunnerModel])? {
        guard let entries = json["data"].list else { return nil }
        var loaded: [RunnerModel] = [], installed: [RunnerModel] = []
        for entry in entries {
            guard let id = entry["id"].string else { continue }
            var model = RunnerModel(
                runner: .lmStudio, name: id, title: id, quantization: entry["quantization"].string, size: nil, sizeSource: .file,
                generates: !(entry["type"].string ?? "llm").hasPrefix("embedding")
            )
            installed.append(model)
            if entry["state"].string == "loaded" {
                model.context = entry["loaded_context_length"].int
                loaded.append(model)
            }
        }
        return (loaded, installed)
    }

    /// The `stats` of LM Studio's own chat endpoints. The two APIs name the first-token time differently.
    static func lmStudioSpeed(_ json: JSONValue) -> RunnerSpeedResult? {
        let stats = json["stats"]
        guard let rate = stats["tokens_per_second"].number, rate > 0 else { return nil }
        return RunnerSpeedResult(
            tokensPerSecond: rate,
            firstToken: stats["time_to_first_token_seconds"].number ?? stats["time_to_first_token"].number,
            tokens: stats["total_output_tokens"].int ?? json["usage"]["completion_tokens"].int ?? 0
        )
    }

    // OpenAI-style servers

    /// The ids in `GET /v1/models`, or nil when the answer is not such a list.
    static func openAIModels(_ json: JSONValue) -> [JSONValue]? {
        guard let entries = json["data"].list else { return nil }
        return entries.filter { $0["id"].string != nil }
    }

    /// llama.cpp's server names itself in `owned_by`.
    static func isLlamaCpp(_ entries: [JSONValue]) -> Bool { entries.contains { $0["owned_by"].string == "llamacpp" } }

    /// One entry of llama.cpp's list. A plain server has one model and it is in memory; started without a model
    /// it lists every one it could load, each with a `status`.
    static func llamaModel(_ entry: JSONValue) -> (model: RunnerModel, loaded: Bool)? {
        guard let id = entry["id"].string else { return nil }
        var title = (id as NSString).lastPathComponent
        if title.lowercased().hasSuffix(".gguf") { title = String(title.dropLast(5)) }
        let meta = entry["meta"]
        let model = RunnerModel(
            runner: .llamaCpp, name: id, title: title,
            parameters: meta["n_params"].number.map(RunnerMath.parameters), quantization: RunnerMath.quantization(in: title),
            size: meta["size"].bytes, sizeSource: .file
        )
        let state = entry["status"]["value"].string
        return (model, state == nil || state == "loaded")
    }

    /// The last chunks of a streamed chat completion: llama.cpp's own `timings`, and the token count either way.
    struct StreamFigures: Equatable {
        var tokens: Int?
        var perSecond: Double?
        var promptSeconds: Double?
    }

    static func streamFigures(_ chunk: JSONValue, into figures: inout StreamFigures) {
        let timings = chunk["timings"]
        if let rate = timings["predicted_per_second"].number, rate > 0 { figures.perSecond = rate }
        if let prompt = timings["prompt_ms"].number { figures.promptSeconds = prompt / 1000 }
        if let count = timings["predicted_n"].int ?? chunk["usage"]["completion_tokens"].int { figures.tokens = count }
    }

    /// A chunk's text, whichever field it came in.
    static func streamText(_ chunk: JSONValue) -> String? {
        let delta = chunk["choices"].array.first?["delta"] ?? JSONValue(nil)
        return delta["content"].string ?? delta["reasoning_content"].string ?? delta["reasoning"].string
    }

    /// The runner's counters when it sent them; otherwise the stream itself, timed. A stream's first token marks
    /// the start of the clock, so the rate is the tokens after it over the time after it.
    static func streamSpeed(_ figures: StreamFigures, chunks: Int, first: Double?, last: Double?) -> RunnerSpeedResult? {
        let tokens = figures.tokens ?? chunks
        if let rate = figures.perSecond {
            return RunnerSpeedResult(tokensPerSecond: rate, firstToken: figures.promptSeconds ?? first, tokens: tokens)
        }
        guard let first, let last, let rate = RunnerMath.streamRate(tokens: tokens, first: first, last: last) else { return nil }
        return RunnerSpeedResult(tokensPerSecond: rate, firstToken: first, tokens: tokens)
    }

    /// What a runner says went wrong, in its own words, cut short.
    static func errorText(_ json: JSONValue) -> String? {
        guard let text = json["error"].string ?? json["error"]["message"].string ?? json["message"].string else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 90 ? String(line.prefix(88)) + "…" : line
    }

    // Dates

    private static let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Ollama writes times with anything from no to nine decimals of a second, and either `Z` or an offset. The
    /// system's parser wants exactly none or exactly three, so the decimals are taken off and added back.
    static func date(_ text: String?) -> Date? {
        guard let text, let t = text.firstIndex(of: "T") else { return nil }
        var whole = text
        var fraction = 0.0
        if let dot = text[t...].firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let end = text.index(dot, offsetBy: digits.count + 1)
            fraction = Double("0." + digits) ?? 0
            whole = String(text[..<dot]) + String(text[end...])
        }
        guard let date = stamp.date(from: whole) else { return nil }
        // Go's zero time is how a runner says "no time set".
        return date.timeIntervalSince1970 < 0 ? nil : date.addingTimeInterval(fraction)
    }
}

// MARK: - Arithmetic and wording

enum RunnerMath {
    static func tokensPerSecond(tokens: Int, nanoseconds: Double) -> Double? {
        guard tokens > 0, nanoseconds > 0 else { return nil }
        return Double(tokens) / nanoseconds * 1e9
    }

    static func streamRate(tokens: Int, first: Double, last: Double) -> Double? {
        guard tokens > 1, last > first else { return nil }
        return Double(tokens - 1) / (last - first)
    }

    /// What each of one runner's loaded models holds. A size the runner gave stands. Models without one share,
    /// equally, what the runner's processes hold beyond the sizes that are known; with no process to go by they
    /// stay unknown.
    static func held(sizes: [UInt64?], process: UInt64?) -> [UInt64?] {
        let known = sizes.compactMap { $0 }.reduce(0, +)
        let unknown = sizes.filter { $0 == nil }.count
        guard unknown > 0, let process else { return sizes }
        let share = process > known ? (process - known) / UInt64(unknown) : 0
        return sizes.map { $0 ?? share }
    }

    /// The headline bar: the models, then whatever else is in use. Models are never drawn past the memory there is.
    static func bar(models: [UInt64], used: UInt64, total: UInt64) -> (models: [UInt64], others: UInt64) {
        let sum = models.reduce(0, +)
        guard sum > total, sum > 0 else { return (models, used > sum ? used - sum : 0) }
        return (models.map { UInt64(Double($0) * Double(total) / Double(sum)) }, 0)
    }

    /// "100% GPU", "71% GPU · 29% CPU", "100% CPU", as `ollama ps` puts it.
    static func placement(size: UInt64?, onGraphics: UInt64?) -> String? {
        guard let size, size > 0, let onGraphics else { return nil }
        let share = Int((min(Double(onGraphics) / Double(size), 1) * 100).rounded())
        if share >= 100 { return "100% GPU" }
        if share <= 0 { return "100% CPU" }
        return "\(share)% GPU · \(100 - share)% CPU"
    }

    /// "unloads in 4 min". A runner told to keep a model for good sets a time centuries away.
    static func unloads(_ expires: Date?, now: Date) -> String? {
        guard let expires else { return nil }
        let left = expires.timeIntervalSince(now)
        if left > 366 * 86_400 { return "stays loaded" }
        if left <= 0 { return "unloading" }
        if left < 59.5 { return "unloads in \(max(1, Int(left.rounded()))) s" }
        if left < 3570 { return "unloads in \(Int((left / 60).rounded())) min" }
        if left < 47.5 * 3600 { return "unloads in \(Int((left / 3600).rounded())) h" }
        return "unloads in \(Int((left / 86_400).rounded())) days"
    }

    /// 8030261312 → "8.0B"
    static func parameters(_ count: Double) -> String {
        if count >= 1e9 { return String(format: count >= 99.5e9 ? "%.0fB" : "%.1fB", count / 1e9) }
        if count >= 1e6 { return String(format: "%.0fM", count / 1e6) }
        return String(format: "%.0fK", count / 1e3)
    }

    /// The quantization a file name carries: "Q4_K_M", "F16", "8bit".
    static func quantization(in name: String) -> String? {
        let pattern = #"(?<![A-Za-z0-9])(Q[0-9][A-Za-z0-9_]*|BF16|F16|F32|[0-9]{1,2}bit)(?![A-Za-z0-9])"#
        guard let range = name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let found = String(name[range])
        return found.lowercased().hasSuffix("bit") ? found.lowercased() : found.uppercased()
    }

    /// "One model loaded", "Two models loaded", "14 models loaded"
    static func loadedPhrase(_ count: Int) -> String {
        let words = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten", "Eleven", "Twelve"]
        let number = count < words.count ? words[max(count, 0)] : "\(count)"
        return "\(number) \(count == 1 ? "model" : "models") loaded"
    }
}

// MARK: - Where the runners are asked

/// The addresses asked. Always this Mac: a model can be made to work from here, so nothing else is accepted.
struct RunnerEndpoints: Equatable {
    var ollama: URL?
    var lmStudio: URL?
    /// OpenAI-style servers: llama.cpp's and MLX's. Nil means their usual ports, and whatever port a running one
    /// was started on.
    var local: URL?
    /// Runners whose address came from a debug switch, which is what lets a test press Speed by itself.
    var standIns: Set<String> = []
    /// With a stand-in for the OpenAI-style server: what to take it for, and which model it has in memory.
    var localKind: RunnerKind?
    var localModel: String?

    static let localPorts = [8080, 9931]

    /// `http://127.0.0.1:<port>`, `http://localhost:<port>` or `http://[::1]:<port>`, and nothing else.
    static func loopback(_ text: String) -> URL? {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespaces)), parts.scheme == "http",
              let host = parts.host, ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased()),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/" else { return nil }
        var clean = URLComponents()
        clean.scheme = "http"
        clean.host = host
        clean.port = parts.port
        return clean.url
    }

    static func local(port: Int) -> URL { URL(string: "http://127.0.0.1:\(port)")! }

    /// Debug: DOTMETER_OLLAMA_BASE, DOTMETER_LMSTUDIO_BASE and DOTMETER_LOCALSERVER_BASE point each reader at a
    /// stand-in on this Mac for one run; `off` asks nobody. Anything that is not this Mac is refused, and that
    /// runner is then not asked at all, so a mistyped switch can never reach a real one.
    static func from(_ env: [String: String], warn: Bool = true) -> RunnerEndpoints {
        var endpoints = RunnerEndpoints(ollama: local(port: 11434), lmStudio: local(port: 1234), local: nil)
        func override(_ key: String, _ name: String) -> URL?? {
            guard let text = env[key] else { return nil }
            endpoints.standIns.insert(name)
            if text == "off" { return .some(nil) }
            guard let url = loopback(text) else {
                if warn { FileHandle.standardError.write(Data("\(key) is not an address on this Mac, so it is not asked\n".utf8)) }
                return .some(nil)
            }
            return url
        }
        if let url = override("DOTMETER_OLLAMA_BASE", "ollama") { endpoints.ollama = url }
        if let url = override("DOTMETER_LMSTUDIO_BASE", "lmStudio") { endpoints.lmStudio = url }
        if let url = override("DOTMETER_LOCALSERVER_BASE", "local") {
            // A refused or switched-off address must not fall back to the usual ports.
            endpoints.local = url ?? URL(string: "http://127.0.0.1:0")
            endpoints.localKind = env["DOTMETER_LOCALSERVER_KIND"].flatMap(RunnerKind.init(rawValue:))
            endpoints.localModel = env["DOTMETER_LOCALSERVER_MODEL"]
        }
        return endpoints
    }
}

// MARK: - Asking

enum RunnerHTTP {
    struct Answer {
        var status: Int
        var json: JSONValue
    }

    private static func session(request: TimeInterval, resource: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request
        configuration.timeoutIntervalForResource = resource
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        // This Mac only, so never by way of a proxy.
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    /// Lists: a runner on this Mac answers in milliseconds, so one that has not within a second and a half is
    /// treated as silent until the next refresh.
    static let quick = session(request: 1.5, resource: 3)
    /// A speed test: a large model can take a while over its first token.
    static let patient = session(request: 90, resource: 180)

    static func url(_ base: URL, _ path: String) -> URL {
        URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) ?? base
    }

    /// Nil when nothing answered: the port refused, or the wait ran out.
    static func get(_ base: URL, _ path: String) async -> Answer? {
        guard base.port != 0, let (data, response) = try? await quick.data(from: url(base, path)),
              let http = response as? HTTPURLResponse else { return nil }
        return Answer(status: http.statusCode, json: JSONValue(data: data.count > 4_000_000 ? Data() : data))
    }

    static func post(_ base: URL, _ path: String, _ body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url(base, path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

enum RunnerReader {
    /// Ollama: `/api/ps` every time, the list on disk and the version when asked for.
    static func ollama(base: URL, installed: Bool, version: Bool) async -> RunnerReading {
        var reading = RunnerReading(kind: .ollama, base: base)
        async let running = RunnerHTTP.get(base, "/api/ps")
        async let onDisk = installed ? await RunnerHTTP.get(base, "/api/tags") : nil
        async let about = version ? await RunnerHTTP.get(base, "/api/version") : nil
        guard let ps = await running, ps.status == 200, let loaded = RunnerDecode.ollamaLoaded(ps.json) else {
            _ = await (onDisk, about)
            return reading
        }
        reading.answered = true
        reading.loaded = loaded
        if let tags = await onDisk, tags.status == 200 { reading.installed = RunnerDecode.ollamaInstalled(tags.json) }
        if let about = await about { reading.version = RunnerDecode.ollamaVersion(about.json) }
        return reading
    }

    /// LM Studio: its newest API first, then the one before, then the plain OpenAI list, which cannot say what is
    /// in memory. `variant` is the one that answered last time, asked alone while it keeps answering.
    static func lmStudio(base: URL, variant: String?) async -> RunnerReading {
        var reading = RunnerReading(kind: .lmStudio, base: base)
        let order = variant.map { [$0] } ?? ["v1", "v0", "openai"]
        for name in order {
            let path = name == "v1" ? "/api/v1/models" : (name == "v0" ? "/api/v0/models" : "/v1/models")
            guard let answer = await RunnerHTTP.get(base, path) else { return reading }
            if answer.status == 401 || answer.status == 403 {
                reading.answered = true
                reading.note = "its server wants an API token"
                return reading
            }
            guard answer.status == 200 else { continue }
            let lists: (loaded: [RunnerModel], installed: [RunnerModel])?
            switch name {
            case "v1": lists = RunnerDecode.lmStudioV1(answer.json)
            case "v0": lists = RunnerDecode.lmStudioV0(answer.json)
            default:
                lists = RunnerDecode.openAIModels(answer.json).map { entries in
                    ([], entries.compactMap { $0["id"].string }.map { RunnerModel(runner: .lmStudio, name: $0, title: $0, sizeSource: .file) })
                }
            }
            guard let lists else { continue }
            reading.answered = true
            reading.loaded = lists.loaded
            reading.installed = lists.installed
            reading.variant = name
            if name == "openai" { reading.note = "this version does not say which models are loaded" }
            return reading
        }
        return reading
    }

    /// What `/props` said about a llama.cpp model, kept so it is asked once per model and not on every refresh.
    struct LlamaDetail: Equatable {
        var model: String
        var context: Int?
        var build: String?
    }

    /// An OpenAI-style server: llama.cpp's when it says so, MLX's when its process was found (`mlx`). Anything
    /// else that happens to answer on the port is left alone: it may be a gateway to a model that costs money.
    static func local(base: URL, mlx: (found: Bool, model: String?), known: LlamaDetail?) async -> (reading: RunnerReading, detail: LlamaDetail?)? {
        guard let answer = await RunnerHTTP.get(base, "/v1/models"), answer.status == 200,
              let entries = RunnerDecode.openAIModels(answer.json) else { return nil }
        if RunnerDecode.isLlamaCpp(entries) {
            var reading = RunnerReading(kind: .llamaCpp, base: base, answered: true)
            let models = entries.compactMap(RunnerDecode.llamaModel)
            var detail = known
            if let first = models.first(where: \.loaded)?.model.name, detail?.model != first {
                let props = await RunnerHTTP.get(base, "/props")?.json ?? JSONValue(nil)
                detail = LlamaDetail(model: first, context: props["default_generation_settings"]["n_ctx"].int, build: props["build_info"].string)
            }
            reading.loaded = models.filter(\.loaded).map { entry in
                var model = entry.model
                if model.name == detail?.model { model.context = detail?.context }
                return model
            }
            reading.installed = models.map(\.model)
            // "b6123-0a1b2c3d": the build number is the part people know it by.
            reading.version = detail?.build.map { String($0.split(separator: "-").first ?? Substring($0)) }
            return (reading, detail)
        }
        guard mlx.found else { return nil }
        var reading = RunnerReading(kind: .mlx, base: base, answered: true)
        // MLX's server lists everything in the download cache and marks none of it. The one in memory is the
        // one it was started with, when the command line names it.
        reading.installed = entries.compactMap { $0["id"].string }.map { RunnerModel(runner: .mlx, name: $0, title: $0, quantization: RunnerMath.quantization(in: $0), sizeSource: .file) }
        if let model = mlx.model {
            let title = model.split(separator: "/").suffix(2).joined(separator: "/")
            reading.loaded = [RunnerModel(runner: .mlx, name: model, title: title, quantization: RunnerMath.quantization(in: title), sizeSource: .process)]
        } else {
            reading.note = "its server does not say which model is loaded"
        }
        return (reading, nil)
    }
}

// MARK: - Speed

/// One short fixed prompt to a model that is already in memory, timed by the runner's own counters. It is the
/// only thing in this area that makes a model work, and it runs only when its button is pressed.
enum RunnerSpeed {
    static let prompt = "Count from one to twenty in words."
    static let tokens = 48

    enum Outcome: Equatable {
        case done(RunnerSpeedResult)
        case failed(String)
    }

    static let unloaded = Outcome.failed("No longer loaded")
    static let silent = Outcome.failed("The runner did not answer")
    static let noFigures = Outcome.failed("The runner gave no figures")

    static func measure(_ model: RunnerModel, base: URL, variant: String?) async -> Outcome {
        switch model.runner {
        case .ollama: return await ollama(model, base: base)
        case .lmStudio: return await lmStudio(model, base: base, variant: variant)
        case .llamaCpp, .mlx: return await stream(model, base: base)
        }
    }

    /// Asked again just before the prompt goes: a runner loads whatever a request names, and a model that
    /// has been unloaded since the page last read the list must not be brought back by a speed test.
    private static func ollama(_ model: RunnerModel, base: URL) async -> Outcome {
        guard let ps = await RunnerHTTP.get(base, "/api/ps") else { return silent }
        guard RunnerDecode.ollamaLoaded(ps.json)?.contains(where: { $0.name == model.name }) == true else { return unloaded }
        // No `keep_alive`: the runner then keeps the time the model was loaded with.
        let request = RunnerHTTP.post(base, "/api/generate", [
            "model": model.name, "prompt": prompt, "stream": true, "options": ["num_predict": tokens, "temperature": 0],
        ])
        do {
            let started = Date()
            let (bytes, response) = try await RunnerHTTP.patient.bytes(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            var first: Double?
            var final = JSONValue(nil)
            for try await line in bytes.lines {
                let json = JSONValue(text: line)
                if let error = RunnerDecode.errorText(json) { return .failed(error) }
                if first == nil, json["response"].string != nil || json["thinking"].string != nil { first = Date().timeIntervalSince(started) }
                if json["done"].bool == true { final = json }
            }
            guard ok else { return silent }
            return RunnerDecode.ollamaSpeed(final, wallFirst: first).map(Outcome.done) ?? noFigures
        } catch {
            return silent
        }
    }

    private static func lmStudio(_ model: RunnerModel, base: URL, variant: String?) async -> Outcome {
        let reading = await RunnerReader.lmStudio(base: base, variant: variant)
        guard reading.answered else { return silent }
        guard reading.loaded.contains(where: { $0.name == model.name }) else { return unloaded }
        let request: URLRequest
        if reading.variant == "v1" {
            request = RunnerHTTP.post(base, "/api/v1/chat", ["model": model.name, "input": prompt, "max_output_tokens": tokens, "temperature": 0, "store": false])
        } else {
            request = RunnerHTTP.post(base, "/api/v0/chat/completions", [
                "model": model.name, "messages": [["role": "user", "content": prompt]], "max_tokens": tokens, "temperature": 0, "stream": false,
            ])
        }
        guard let (data, response) = try? await RunnerHTTP.patient.data(for: request) else { return silent }
        let json = JSONValue(data: data)
        if (response as? HTTPURLResponse)?.statusCode != 200 { return RunnerDecode.errorText(json).map(Outcome.failed) ?? silent }
        return RunnerDecode.lmStudioSpeed(json).map(Outcome.done) ?? noFigures
    }

    /// llama.cpp sends its own timings with the last chunk. MLX sends a token count at most, so its stream is timed.
    private static func stream(_ model: RunnerModel, base: URL) async -> Outcome {
        guard let list = await RunnerHTTP.get(base, "/v1/models"), let entries = RunnerDecode.openAIModels(list.json) else { return silent }
        if model.runner == .llamaCpp, entries.compactMap(RunnerDecode.llamaModel).first(where: { $0.model.name == model.name })?.loaded != true { return unloaded }
        // MLX loads whatever model a request names. "default_model" is its own word for the one it was started with.
        let request = RunnerHTTP.post(base, "/v1/chat/completions", [
            "model": model.runner == .mlx ? "default_model" : model.name, "messages": [["role": "user", "content": prompt]],
            "max_tokens": tokens, "temperature": 0, "stream": true, "stream_options": ["include_usage": true],
        ])
        do {
            let started = Date()
            let (bytes, response) = try await RunnerHTTP.patient.bytes(for: request)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            var figures = RunnerDecode.StreamFigures()
            var chunks = 0
            var first: Double?, last: Double?
            for try await line in bytes.lines {
                guard ok else { return RunnerDecode.errorText(JSONValue(text: line)).map(Outcome.failed) ?? silent }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                let chunk = JSONValue(text: payload)
                if let error = RunnerDecode.errorText(chunk) { return .failed(error) }
                if RunnerDecode.streamText(chunk) != nil {
                    let now = Date().timeIntervalSince(started)
                    if first == nil { first = now }
                    last = now
                    chunks += 1
                }
                RunnerDecode.streamFigures(chunk, into: &figures)
            }
            guard ok else { return silent }
            return RunnerDecode.streamSpeed(figures, chunks: chunks, first: first, last: last).map(Outcome.done) ?? noFigures
        } catch {
            return silent
        }
    }
}
