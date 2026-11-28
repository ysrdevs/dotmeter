import Foundation

/// Answers as the runners' own documentation gives them, with invented model names where a test adds its own.
/// Kept here so the decoders are checked against the shapes they were written for, without a runner.
private enum RunnerFixtures {
    static let ollamaPS = """
    {"models":[{"name":"gemma4","model":"gemma4","size":6591830464,"digest":"c6eb396dbd5992bbe3f5cdb947e8bbc0ee413d7c17e2beaae69f5d569cf982eb",
    "details":{"parent_model":"","format":"gguf","family":"gemma4","families":["gemma4"],"parameter_size":"8.0B","quantization_level":"Q4_K_M"},
    "expires_at":"2025-10-17T16:47:07.93355-07:00","size_vram":5333539264,"context_length":4096}]}
    """
    /// The older shape: no context length, and everything on the graphics chip.
    static let ollamaPSOld = """
    {"models":[{"name":"mistral:latest","model":"mistral:latest","size":5137025024,"digest":"2ae6f6dd7a3dd734790bbbf58b8909a606e0e7e97e94b7604e0aa7ae4490e6d8",
    "details":{"parent_model":"","format":"gguf","family":"llama","families":["llama"],"parameter_size":"7.2B","quantization_level":"Q4_0"},
    "expires_at":"2024-06-04T14:38:31.83753-07:00","size_vram":5137025024}]}
    """
    /// Fields missing, a field of the wrong type, an entry with no name, and something that is not an entry.
    static let ollamaPSSparse = """
    {"models":[{"name":"harbor:70b"},{"model":"saltmarsh:8b","size":"large","expires_at":"0001-01-01T00:00:00Z","details":null},{"size":12},"what"]}
    """
    static let ollamaTags = """
    {"models":[{"name":"deepseek-r1:latest","model":"deepseek-r1:latest","modified_at":"2025-05-10T08:06:48.639712648-07:00","size":4683075271,
    "digest":"0a8c266910232fd3291e71e5ba1e058cc5af9d411192cf88b6d30e92b6e73163",
    "details":{"parent_model":"","format":"gguf","family":"qwen2","families":["qwen2"],"parameter_size":"7.6B","quantization_level":"Q4_K_M"}},
    {"name":"llama3.2:latest","model":"llama3.2:latest","modified_at":"2025-05-04T17:37:44.706015396-07:00","size":2019393189,
    "digest":"a80c4f17acd55265feec403c7aef86be0c25983ab279d83f3bcd3abbcb5b8b72",
    "details":{"format":"gguf","family":"llama","families":["llama"],"parameter_size":"3.2B","quantization_level":"Q4_K_M"}},
    {"name":"kestrel-embed:latest","size":274302450,"details":{"family":"nomic-bert","parameter_size":"137M","quantization_level":"F16"}}]}
    """
    static let ollamaFinal = """
    {"model":"llama3.2","created_at":"2023-08-04T19:22:45.499127Z","response":"","done":true,"context":[1,2,3],"total_duration":10706818083,
    "load_duration":6338219291,"prompt_eval_count":26,"prompt_eval_duration":130079000,"eval_count":259,"eval_duration":4232710000}
    """
    static let lmStudioV1 = """
    {"models":[{"type":"llm","publisher":"google","key":"google/gemma-4-26b-a4b","display_name":"Gemma 4 26B A4B","architecture":"gemma4",
    "quantization":{"name":"Q4_K_M","bits_per_weight":4},"size_bytes":17990911801,"params_string":"26B-A4B",
    "loaded_instances":[{"id":"google/gemma-4-26b-a4b","config":{"context_length":4096,"eval_batch_size":512,"parallel":4,"flash_attention":true}}],
    "max_context_length":262144,"format":"gguf","capabilities":{"vision":true,"trained_for_tool_use":true},"description":null},
    {"type":"llm","publisher":"thistle","key":"thistle/quince-27b","display_name":"Quince 27B","quantization":null,"size_bytes":15000000000,
    "params_string":null,"loaded_instances":[],"max_context_length":null,"format":"mlx"},
    {"type":"embedding","publisher":"gaianet","key":"text-embedding-nomic-embed-text-v1.5-embedding","display_name":"Nomic Embed Text v1.5",
    "quantization":{"name":"F16","bits_per_weight":16},"size_bytes":274290560,"params_string":null,
    "loaded_instances":[{"id":"text-embedding-nomic-embed-text-v1.5-embedding","config":{"context_length":2048}}],"max_context_length":2048,"format":"gguf"}]}
    """
    static let lmStudioV0 = """
    {"object":"list","data":[{"id":"qwen2-vl-7b-instruct","object":"model","type":"vlm","publisher":"mlx-community","arch":"qwen2_vl",
    "compatibility_type":"mlx","quantization":"4bit","state":"not-loaded","max_context_length":32768},
    {"id":"meta-llama-3.1-8b-instruct","object":"model","type":"llm","publisher":"lmstudio-community","arch":"llama","compatibility_type":"gguf",
    "quantization":"Q4_K_M","state":"loaded","max_context_length":131072,"loaded_context_length":8192},
    {"id":"text-embedding-nomic-embed-text-v1.5","object":"model","type":"embeddings","publisher":"nomic-ai","arch":"nomic-bert",
    "compatibility_type":"gguf","quantization":"Q4_0","state":"not-loaded","max_context_length":2048}]}
    """
    static let lmStudioV0Chat = """
    {"id":"chatcmpl-i3gkjwthhw96whukek9tz","object":"chat.completion","created":1731990317,"model":"granite-3.0-2b-instruct",
    "choices":[{"index":0,"logprobs":null,"finish_reason":"stop","message":{"role":"assistant","content":"Greetings"}}],
    "usage":{"prompt_tokens":24,"completion_tokens":53,"total_tokens":77},
    "stats":{"tokens_per_second":51.43709529007664,"time_to_first_token":0.111,"generation_time":0.954,"stop_reason":"eosFound"},
    "model_info":{"arch":"granite","quant":"Q4_K_M","format":"gguf","context_length":4096}}
    """
    static let lmStudioV1Chat = """
    {"model_instance_id":"qwen/qwen3-vl-4b","output":[{"type":"message","content":"A red square."}],
    "stats":{"input_tokens":17,"total_output_tokens":50,"reasoning_output_tokens":0,"tokens_per_second":51.03762685242662,"time_to_first_token_seconds":0.814},
    "response_id":"resp_0182bd7c479d7451f9a35471f9c26b34de87a7255856b9a4"}
    """
    static let llamaModels = """
    {"object":"list","data":[{"id":"../models/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf","object":"model",
    "architecture":{"input_modalities":["text"],"output_modalities":["text"]},"created":1735142223,"owned_by":"llamacpp",
    "meta":{"vocab_type":2,"n_vocab":128256,"n_ctx_train":131072,"n_embd":4096,"n_params":8030261312,"size":4912898304}}]}
    """
    /// Started without a model: everything it could load, each with a state. And one whose details are not in yet.
    static let llamaRouter = """
    {"object":"list","data":[{"id":"quartz-mini-3b-Q5_K_M","object":"model","owned_by":"llamacpp","status":{"value":"loaded"},"meta":null},
    {"id":"juniper-14b-Q4_K_M","object":"model","owned_by":"llamacpp","status":{"value":"unloaded"}}]}
    """
    static let llamaLastChunk = """
    {"choices":[{"index":0,"delta":{},"finish_reason":"length"}],"timings":{"cache_n":236,"prompt_n":1,"prompt_ms":30.958,"prompt_per_token_ms":30.958,
    "prompt_per_second":32.301828283480845,"predicted_n":35,"predicted_ms":661.064,"predicted_per_token_ms":18.887542857142858,"predicted_per_second":52.94494935437416}}
    """
    static let mlxModels = """
    {"object":"list","data":[{"id":"thistle-community/Juniper-14B-4bit","object":"model","created":1764300000},
    {"id":"thistle-community/Sorrel-3B-8bit","object":"model","created":1764300000}]}
    """
    static let usageChunk = """
    {"id":"c1","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":12,"completion_tokens":21,"total_tokens":33}}
    """
}

extension DebugTools {
    /// `Dotmeter --self-test models`: the decoders against recorded answers, the wording, the arithmetic, which
    /// process is which runner, and the rule that only this Mac is ever asked. No runner is contacted, unless a
    /// stand-in is named with DOTMETER_OLLAMA_BASE, DOTMETER_LMSTUDIO_BASE or DOTMETER_LOCALSERVER_BASE, and
    /// then only the stand-in is.
    @MainActor
    static func modelsSelfTest(models: AppModels) async {
        var failed = 0, passed = 0
        func check(_ name: String, _ ok: Bool, _ got: Any = "") {
            if ok { passed += 1 } else { failed += 1 }
            print("\(ok ? "ok" : "FAILED") \(name)\(ok ? "" : " (got \(got))")")
        }
        func close(_ a: Double?, _ b: Double, _ within: Double = 0.005) -> Bool { a.map { abs($0 - b) <= within } ?? false }
        let gib: UInt64 = 1_073_741_824

        // Ollama
        check("Ollama's version is read", RunnerDecode.ollamaVersion(JSONValue(text: #"{"version":"0.12.6"}"#)) == "0.12.6")
        let ps = RunnerDecode.ollamaLoaded(JSONValue(text: RunnerFixtures.ollamaPS)) ?? []
        check("a loaded Ollama model: name, size, parameters, quantization", ps.count == 1 && ps.first?.name == "gemma4" && ps.first?.size == 6_591_830_464 && ps.first?.parameters == "8.0B" && ps.first?.quantization == "Q4_K_M", ps)
        check("its share on the graphics chip and its context", ps.first?.onGraphics == 5_333_539_264 && ps.first?.context == 4096, ps)
        check("its unload time, with five decimals and an offset", close(ps.first?.expires?.timeIntervalSince1970, 1_760_744_827.93355, 0.001), ps.first?.expires as Any)
        let old = RunnerDecode.ollamaLoaded(JSONValue(text: RunnerFixtures.ollamaPSOld)) ?? []
        check("the older answer, with no context length", old.count == 1 && old.first?.context == nil && old.first?.onGraphics == old.first?.size, old)
        let sparse = RunnerDecode.ollamaLoaded(JSONValue(text: RunnerFixtures.ollamaPSSparse)) ?? []
        check("fields missing or of the wrong type are left out, not guessed", sparse.map(\.name) == ["harbor:70b", "saltmarsh:8b"] && sparse.allSatisfy { $0.size == nil && $0.expires == nil && $0.parameters == nil }, sparse)
        check("an empty list is a runner with nothing loaded", RunnerDecode.ollamaLoaded(JSONValue(text: #"{"models":[]}"#))?.isEmpty == true)
        check("an answer of another shape is no answer", RunnerDecode.ollamaLoaded(JSONValue(text: #"{"error":"nope"}"#)) == nil && RunnerDecode.ollamaLoaded(JSONValue(text: "<html>")) == nil && RunnerDecode.ollamaLoaded(JSONValue(text: "[1,2]")) == nil)
        let tags = RunnerDecode.ollamaInstalled(JSONValue(text: RunnerFixtures.ollamaTags)) ?? []
        check("installed Ollama models and their sizes on disk", tags.map(\.name) == ["deepseek-r1:latest", "llama3.2:latest", "kestrel-embed:latest"] && tags.compactMap(\.size).reduce(0, +) == 4_683_075_271 + 2_019_393_189 + 274_302_450, tags)
        check("an embedding model is known not to answer prompts", tags.last?.generates == false && tags.first?.generates == true)
        let generated = RunnerDecode.ollamaSpeed(JSONValue(text: RunnerFixtures.ollamaFinal), wallFirst: 9)
        check("tokens a second from Ollama's counters: 259 in 4.23271 s is 61.19", close(generated?.tokensPerSecond, 61.19), generated as Any)
        check("first token from its counters: loading plus the prompt, 6.468 s", close(generated?.firstToken, 6.468298291, 1e-6), generated as Any)
        check("with no prompt time, the clock's own first token stands in", RunnerDecode.ollamaSpeed(JSONValue(text: #"{"eval_count":10,"eval_duration":500000000}"#), wallFirst: 0.3) == RunnerSpeedResult(tokensPerSecond: 20, firstToken: 0.3, tokens: 10))
        check("no counters, no result", RunnerDecode.ollamaSpeed(JSONValue(text: #"{"done":true,"response":""}"#), wallFirst: 0.3) == nil && RunnerDecode.ollamaSpeed(JSONValue(text: #"{"eval_count":0,"eval_duration":0}"#), wallFirst: nil) == nil)

        // LM Studio
        let v1 = RunnerDecode.lmStudioV1(JSONValue(text: RunnerFixtures.lmStudioV1))
        check("LM Studio's newer list: three on disk, two in memory", v1?.installed.count == 3 && v1?.loaded.map(\.name) == ["google/gemma-4-26b-a4b", "text-embedding-nomic-embed-text-v1.5-embedding"], v1 as Any)
        check("its loaded model: title, parameters, quantization, context, size on disk", v1?.loaded.first.map { $0.title == "Gemma 4 26B A4B" && $0.parameters == "26B-A4B" && $0.quantization == "Q4_K_M" && $0.context == 4096 && $0.size == 17_990_911_801 && $0.sizeSource == .file } == true, v1?.loaded.first as Any)
        check("nulls in it are read as unknown", v1?.installed.first { $0.name == "thistle/quince-27b" }.map { $0.quantization == nil && $0.parameters == nil } == true)
        check("its embedding model cannot be timed", v1?.loaded.last?.generates == false)
        let v0 = RunnerDecode.lmStudioV0(JSONValue(text: RunnerFixtures.lmStudioV0))
        check("LM Studio's older list: the one marked loaded", v0?.installed.count == 3 && v0?.loaded.map(\.name) == ["meta-llama-3.1-8b-instruct"] && v0?.loaded.first?.context == 8192 && v0?.loaded.first?.size == nil, v0 as Any)
        check("an empty LM Studio list, either shape", RunnerDecode.lmStudioV1(JSONValue(text: #"{"models":[]}"#))?.installed.isEmpty == true && RunnerDecode.lmStudioV0(JSONValue(text: #"{"object":"list","data":[]}"#))?.loaded.isEmpty == true)
        check("one shape is not taken for the other", RunnerDecode.lmStudioV1(JSONValue(text: RunnerFixtures.lmStudioV0)) == nil && RunnerDecode.lmStudioV0(JSONValue(text: RunnerFixtures.lmStudioV1)) == nil)
        let chat0 = RunnerDecode.lmStudioSpeed(JSONValue(text: RunnerFixtures.lmStudioV0Chat)), chat1 = RunnerDecode.lmStudioSpeed(JSONValue(text: RunnerFixtures.lmStudioV1Chat))
        check("LM Studio's own figures, older API", close(chat0?.tokensPerSecond, 51.437) && chat0?.firstToken == 0.111 && chat0?.tokens == 53, chat0 as Any)
        check("LM Studio's own figures, newer API, where the first-token field has another name", close(chat1?.tokensPerSecond, 51.038) && chat1?.firstToken == 0.814 && chat1?.tokens == 50, chat1 as Any)
        check("a chat answer with no stats gives no result", RunnerDecode.lmStudioSpeed(JSONValue(text: #"{"output":[]}"#)) == nil)

        // llama.cpp and MLX
        let llamaEntries = RunnerDecode.openAIModels(JSONValue(text: RunnerFixtures.llamaModels)) ?? []
        let llama = llamaEntries.compactMap(RunnerDecode.llamaModel)
        check("llama.cpp's server is known by what it calls itself", RunnerDecode.isLlamaCpp(llamaEntries) && !RunnerDecode.isLlamaCpp(RunnerDecode.openAIModels(JSONValue(text: RunnerFixtures.mlxModels)) ?? []))
        check("its model: a title from the file, parameters, quantization, size", llama.first.map { $0.loaded && $0.model.title == "Meta-Llama-3.1-8B-Instruct-Q4_K_M" && $0.model.parameters == "8.0B" && $0.model.quantization == "Q4_K_M" && $0.model.size == 4_912_898_304 } == true, llama)
        let router = (RunnerDecode.openAIModels(JSONValue(text: RunnerFixtures.llamaRouter)) ?? []).compactMap(RunnerDecode.llamaModel)
        check("started without a model, only the ones it says are loaded count", router.map(\.loaded) == [true, false] && router.first?.model.size == nil, router)
        check("a list that is not a list", RunnerDecode.openAIModels(JSONValue(text: #"{"models":[]}"#)) == nil && RunnerDecode.openAIModels(JSONValue(text: #"{"data":[]}"#))?.isEmpty == true)
        var figures = RunnerDecode.StreamFigures()
        RunnerDecode.streamFigures(JSONValue(text: RunnerFixtures.llamaLastChunk), into: &figures)
        let timed = RunnerDecode.streamSpeed(figures, chunks: 35, first: 0.4, last: 1.1)
        check("llama.cpp's own timings win over the clock", close(timed?.tokensPerSecond, 52.945) && close(timed?.firstToken, 0.030958, 1e-6) && timed?.tokens == 35, timed as Any)
        var counted = RunnerDecode.StreamFigures()
        RunnerDecode.streamFigures(JSONValue(text: RunnerFixtures.usageChunk), into: &counted)
        let clocked = RunnerDecode.streamSpeed(counted, chunks: 20, first: 0.5, last: 1.0)
        check("with a token count only, the stream is timed: 20 more tokens in 0.5 s is 40 a second", clocked == RunnerSpeedResult(tokensPerSecond: 40, firstToken: 0.5, tokens: 21), clocked as Any)
        check("with neither, the chunks are the tokens", RunnerDecode.streamSpeed(RunnerDecode.StreamFigures(), chunks: 11, first: 1, last: 2)?.tokensPerSecond == 10)
        check("a stream of one token has no rate", RunnerDecode.streamSpeed(RunnerDecode.StreamFigures(), chunks: 1, first: 1, last: 1) == nil)
        check("a chunk's text is found wherever it is", RunnerDecode.streamText(JSONValue(text: #"{"choices":[{"delta":{"content":"one"}}]}"#)) == "one" && RunnerDecode.streamText(JSONValue(text: #"{"choices":[{"delta":{"reasoning_content":"hm"}}]}"#)) == "hm" && RunnerDecode.streamText(JSONValue(text: #"{"choices":[]}"#)) == nil)
        check("a runner's error, in its words", RunnerDecode.errorText(JSONValue(text: #"{"error":"model requires more system memory"}"#)) == "model requires more system memory" && RunnerDecode.errorText(JSONValue(text: #"{"error":{"message":"No models loaded"}}"#)) == "No models loaded" && RunnerDecode.errorText(JSONValue(text: #"{"done":true}"#)) == nil)

        // Arithmetic
        check("tokens a second: 48 in 1.2 s is 40", RunnerMath.tokensPerSecond(tokens: 48, nanoseconds: 1.2e9) == 40 && RunnerMath.tokensPerSecond(tokens: 48, nanoseconds: 0) == nil && RunnerMath.tokensPerSecond(tokens: 0, nanoseconds: 1e9) == nil)
        check("a result in words", RunnerSpeedResult(tokensPerSecond: 48.52, firstToken: 0.2496, tokens: 48).text == "48.5 tokens/s · first token in 250 ms" && RunnerSpeedResult(tokensPerSecond: 131.4, firstToken: 1.44, tokens: 48).text == "131 tokens/s · first token in 1.4 s" && RunnerSpeedResult(tokensPerSecond: 7.04, firstToken: nil, tokens: 48).text == "7.0 tokens/s")
        check("parameter counts", RunnerMath.parameters(8_030_261_312) == "8.0B" && RunnerMath.parameters(137_000_000) == "137M" && RunnerMath.parameters(120e9) == "120B")
        check("quantization from a file name", RunnerMath.quantization(in: "Meta-Llama-3.1-8B-Instruct-Q4_K_M") == "Q4_K_M" && RunnerMath.quantization(in: "thistle/Juniper-14B-4bit") == "4bit" && RunnerMath.quantization(in: "nomic-embed-f16") == "F16" && RunnerMath.quantization(in: "Quince-27B") == nil)

        // The memory split
        check("a size the runner gave stands", RunnerMath.held(sizes: [40 * gib, 6 * gib], process: 50 * gib) == [40 * gib, 6 * gib])
        check("models without one share what the processes hold beyond the known", RunnerMath.held(sizes: [40 * gib, nil, nil], process: 60 * gib) == [40 * gib, 10 * gib, 10 * gib])
        check("one model with no size is its runner's whole memory", RunnerMath.held(sizes: [nil], process: 9 * gib) == [9 * gib])
        check("with no process to go by it stays unknown", RunnerMath.held(sizes: [nil, 3 * gib], process: nil) == [nil, 3 * gib])
        check("processes holding less than the known sizes leave nothing to share", RunnerMath.held(sizes: [40 * gib, nil], process: 30 * gib) == [40 * gib, 0])
        let bar = RunnerMath.bar(models: [46 * gib, 15 * gib], used: 114 * gib, total: 512 * gib)
        check("the bar: the models, then what else is in use", bar.models == [46 * gib, 15 * gib] && bar.others == 53 * gib, bar)
        check("models holding more than is counted as used leave no remainder", RunnerMath.bar(models: [46 * gib], used: 30 * gib, total: 512 * gib).others == 0)
        let over = RunnerMath.bar(models: [48 * gib, 24 * gib], used: 60 * gib, total: 64 * gib)
        check("models are never drawn past the memory there is", over.models.reduce(0, +) <= 64 * gib && over.others == 0 && over.models[0] > over.models[1], over)
        check("where a model runs", RunnerMath.placement(size: 100, onGraphics: 100) == "100% GPU" && RunnerMath.placement(size: 100, onGraphics: 71) == "71% GPU · 29% CPU" && RunnerMath.placement(size: 100, onGraphics: 0) == "100% CPU" && RunnerMath.placement(size: 100, onGraphics: nil) == nil && RunnerMath.placement(size: 100, onGraphics: 140) == "100% GPU")

        // The unload-time wording
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func unloads(_ seconds: Double) -> String? { RunnerMath.unloads(now.addingTimeInterval(seconds), now: now) }
        check("unloads in 4 min", unloads(262) == "unloads in 4 min", unloads(262) as Any)
        check("under a minute is counted in seconds", unloads(41) == "unloads in 41 s" && unloads(0.2) == "unloads in 1 s", [unloads(41), unloads(0.2)])
        check("a minute, an hour, hours and days", unloads(75) == "unloads in 1 min" && unloads(3570) == "unloads in 1 h" && unloads(4 * 3600) == "unloads in 4 h" && unloads(5 * 86_400) == "unloads in 5 days", [unloads(75), unloads(3570), unloads(4 * 3600), unloads(5 * 86_400)])
        check("59 minutes stays minutes", unloads(59 * 60) == "unloads in 59 min", unloads(59 * 60) as Any)
        check("kept for good", unloads(290 * 365 * 86_400.0) == "stays loaded")
        check("past its time", unloads(-3) == "unloading" && RunnerMath.unloads(nil, now: now) == nil)
        check("times as Ollama writes them", [
            ("2024-06-04T14:38:31.83753-07:00", 1_717_537_111.83753), ("2025-05-10T08:06:48.639712648-07:00", 1_746_889_608.639712648),
            ("2023-08-04T19:22:45.499127Z", 1_691_176_965.499127), ("2026-11-28T10:00:00Z", 1_795_860_000), ("2026-11-28T10:00:00+01:00", 1_795_856_400),
        ].allSatisfy { close(RunnerDecode.date($0.0)?.timeIntervalSince1970, $0.1, 0.001) })
        check("no time, the zero time and nonsense are all unknown", RunnerDecode.date(nil) == nil && RunnerDecode.date("0001-01-01T00:00:00Z") == nil && RunnerDecode.date("soon") == nil && RunnerDecode.date("") == nil)
        check("how many are loaded, in words", RunnerMath.loadedPhrase(1) == "One model loaded" && RunnerMath.loadedPhrase(2) == "Two models loaded" && RunnerMath.loadedPhrase(14) == "14 models loaded")

        // Which process is which runner
        func kind(_ name: String, _ path: String? = nil, _ arguments: [String]? = nil) -> RunnerKind? { RunnerMatch.kind(name: name, path: path) { arguments } }
        check("Ollama's server and its runners", kind("ollama", "/opt/homebrew/opt/ollama/bin/ollama") == .ollama && kind("Ollama", "/Applications/Ollama.app/Contents/MacOS/Ollama") == .ollama && kind("ollama", "/Applications/Ollama.app/Contents/Resources/ollama") == .ollama)
        check("LM Studio, its helpers and its engines", kind("LM Studio", "/Applications/LM Studio.app/Contents/MacOS/LM Studio") == .lmStudio && kind("LM Studio Helper (GPU)") == .lmStudio && kind("node", "/Users/someone/.lmstudio/.internal/utils/node") == .lmStudio && kind("llmster") == .lmStudio)
        check("llama.cpp's server", kind("llama-server", "/opt/homebrew/bin/llama-server") == .llamaCpp)
        check("MLX's server is a Python process, told by its command line", kind("python3.12", "/usr/bin/python3.12", ["python3.12", "-m", "mlx_lm.server", "--model", "thistle-community/Juniper-14B-4bit"]) == .mlx && kind("Python", nil, ["/x/bin/python", "/x/bin/mlx_lm.server", "--port", "8081"]) == .mlx && kind("python3", nil, ["python3", "-m", "mlx_lm", "server"]) == .mlx)
        check("other Python programs are not", kind("python3.12", nil, ["python3.12", "-m", "http.server"]) == nil && kind("python", "/Users/someone/tools/mlx-audio/.venv/bin/python", ["python", "serve.py"]) == nil && kind("python3", nil, nil) == nil && kind("python3", nil, ["python3", "-m", "mlx_lm", "generate"]) == nil)
        check("nothing else is", kind("Safari", "/Applications/Safari.app/Contents/MacOS/Safari") == nil && kind("llama") == nil && kind("node", "/usr/local/bin/node") == nil && kind("ollamadesk") == nil)
        check("a port and a model on a command line", RunnerMatch.port(in: ["llama-server", "-m", "/models/q.gguf", "--port", "8181"]) == 8181 && RunnerMatch.port(in: ["x", "--port=9000"]) == 9000 && RunnerMatch.port(in: ["x", "--port", "none"]) == nil && RunnerMatch.port(in: ["x"]) == nil && RunnerMatch.model(in: ["llama-server", "-m", "/models/q.gguf"], short: true) == "/models/q.gguf" && RunnerMatch.model(in: ["python", "-m", "mlx_lm.server", "--model", "a/b"], short: false) == "a/b" && RunnerMatch.model(in: ["python", "-m", "mlx_lm.server"], short: false) == nil)
        func made(_ pid: Int32, _ name: String, _ path: String?, _ memory: UInt64, _ cpu: Double, _ gpu: Double) -> ProcessUsage {
            ProcessUsage(pid: pid, ppid: 1, name: name, path: path, cpu: cpu, memory: memory, parentName: nil, gpu: gpu)
        }
        let running = [
            made(11, "ollama", "/opt/homebrew/bin/ollama", 30_000_000, 0.01, 0), made(12, "ollama", "/opt/homebrew/bin/ollama", 46 * gib, 2.0, 0.6),
            made(13, "LM Studio", "/Applications/LM Studio.app/Contents/MacOS/LM Studio", gib, 0.02, 0.01), made(14, "Safari", "/Applications/Safari.app/Contents/MacOS/Safari", gib, 0.3, 0.1),
            made(15, "llama-server", "/opt/homebrew/bin/llama-server", 3 * gib, 0, 0),
        ]
        let matched: [(process: ProcessUsage, kind: RunnerKind, arguments: [String]?)] = running.compactMap { process in
            kind(process.name, process.path).map { (process, $0, process.pid == 15 ? ["llama-server", "-m", "/models/q.gguf", "--port", "8181"] : nil) }
        }
        let usage = RunnerMatch.usage(of: matched)
        check("a runner's processes are added up", usage[.ollama] == RunnerProcess(memory: 46 * gib + 30_000_000, cpu: 2.01, gpu: 0.6, count: 2), usage[.ollama] as Any)
        check("an app's icon comes from its bundle", usage[.lmStudio]?.bundlePath == "/Applications/LM Studio.app" && usage[.ollama]?.bundlePath == nil)
        check("a server's port and model come from its command line", usage[.llamaCpp]?.ports == [8181] && usage[.llamaCpp]?.model == "/models/q.gguf" && usage[.mlx] == nil, usage[.llamaCpp] as Any)
        var block: [UInt8] = [3, 0, 0, 0] + Array("/usr/bin/tool".utf8) + [0, 0, 0]
        for argument in ["tool", "--port", "8081"] { block += Array(argument.utf8) + [0] }
        block += Array("SECRET=1".utf8) + [0]
        check("a command line is read up to its arguments and no further", ProcessArguments.parse(block) == ["tool", "--port", "8081"] && ProcessArguments.parse([1, 0]) == nil && ProcessArguments.parse([9, 0, 0, 0, 65, 0, 66, 0]) == nil)
        check("this process's own command line can be read", ProcessArguments.read(getpid())?.contains("--self-test") == true, ProcessArguments.read(getpid()) as Any)

        // Only this Mac is asked
        for good in ["http://127.0.0.1:11434", "http://localhost:1234", "http://127.0.0.1:8080/", "http://[::1]:11434"] {
            check("\(good) is this Mac", RunnerEndpoints.loopback(good) != nil)
        }
        for bad in ["http://192.168.1.20:11434", "https://127.0.0.1:11434", "http://example.com:11434", "http://127.0.0.1.example.com:11434", "http://127.0.0.1@example.com:11434",
                    "http://user:pw@127.0.0.1:11434", "http://0.0.0.0:11434", "http://127.0.0.1:11434/api/../x", "http://127.0.0.1:11434?x=1", "file:///tmp/x", "127.0.0.1:11434", ""] {
            check("\(bad.isEmpty ? "an empty address" : bad) is refused", RunnerEndpoints.loopback(bad) == nil, RunnerEndpoints.loopback(bad) as Any)
        }
        check("an address keeps its port and loses anything after it", RunnerEndpoints.loopback("http://127.0.0.1:8080/")?.absoluteString == "http://127.0.0.1:8080" && RunnerEndpoints.loopback("http://[::1]:11434")?.port == 11434)
        let usual = RunnerEndpoints.from([:])
        check("with no switches, the runners' usual ports on this Mac", usual.ollama?.absoluteString == "http://127.0.0.1:11434" && usual.lmStudio?.absoluteString == "http://127.0.0.1:1234" && usual.local == nil && usual.standIns.isEmpty)
        let refused = RunnerEndpoints.from(["DOTMETER_OLLAMA_BASE": "http://192.168.1.20:11434", "DOTMETER_LMSTUDIO_BASE": "off", "DOTMETER_LOCALSERVER_BASE": "https://example.com"], warn: false)
        check("a switch pointing off this Mac leaves that runner unasked, not on its usual port", refused.ollama == nil && refused.lmStudio == nil && refused.local?.port == 0, refused)
        let standIn = RunnerEndpoints.from(["DOTMETER_OLLAMA_BASE": "http://127.0.0.1:18434"])
        check("a stand-in on this Mac is used, and is known to be one", standIn.ollama?.port == 18434 && standIn.standIns == ["ollama"] && standIn.lmStudio?.port == 1234)
        check("a request goes to the address it was given", RunnerHTTP.url(URL(string: "http://127.0.0.1:18434")!, "/api/ps").absoluteString == "http://127.0.0.1:18434/api/ps")

        // Putting the page together
        var ollama = RunnerReading(kind: .ollama, base: RunnerEndpoints.local(port: 11434), answered: true, version: "0.15.4")
        ollama.loaded = (RunnerDecode.ollamaLoaded(JSONValue(text: RunnerFixtures.ollamaPS)) ?? []) + sparse.prefix(1)
        ollama.installed = tags
        var studio = RunnerReading(kind: .lmStudio, base: RunnerEndpoints.local(port: 1234), answered: true, variant: "v0")
        studio.loaded = v0?.loaded ?? []
        studio.installed = v0?.installed
        let silentServer = RunnerReading(kind: .llamaCpp, base: RunnerEndpoints.local(port: 8080))
        let picture = RunnersModel.picture(
            readings: [ollama, studio, silentServer],
            processes: [.ollama: RunnerProcess(memory: 20 * gib, cpu: 1, gpu: 0.5, count: 2), .lmStudio: RunnerProcess(memory: 9 * gib, count: 5, bundlePath: "/Applications/LM Studio.app"), .llamaCpp: RunnerProcess(memory: gib, count: 1, ports: [8181])],
            bundleVersions: ["/Applications/LM Studio.app": "0.4.2"]
        )
        check("three runners: two answering, one found by its process alone", picture.runners.map(\.kind) == [.ollama, .lmStudio, .llamaCpp] && picture.runners.map(\.answering) == [true, true, false] && picture.runners.last?.port == 8181, picture.runners)
        check("LM Studio's version comes from its app", picture.runners[1].version == "0.4.2" && picture.runners[0].version == "0.15.4")
        check("a model with no size takes its share of the runner's processes, and the largest comes first", picture.loaded.map(\.model.name) == ["harbor:70b", "meta-llama-3.1-8b-instruct", "gemma4"] && picture.loaded[0].model.size == 20 * gib - 6_591_830_464 && picture.loaded[0].model.sizeSource == .process && picture.loaded[1].model.size == 9 * gib, picture.loaded)
        check("installed models, largest first", picture.installed.first?.name == "deepseek-r1:latest" && picture.installed.count == 6, picture.installed.map(\.name))
        let memory = MemoryStats(total: 512 * gib, used: 114 * gib, app: 0, wired: 0, compressed: 0, cached: 0, swapUsed: 0, swapTotal: 0, pressure: .normal)
        var two = RunnersModel.Picture()
        two.runners = [picture.runners[0]]
        two.loaded = [
            RunnersModel.Loaded(model: RunnerModel(runner: .ollama, name: "harbor:70b", title: "harbor:70b", size: 46 * gib, expires: now.addingTimeInterval(262)), tone: 0),
            RunnersModel.Loaded(model: RunnerModel(runner: .ollama, name: "saltmarsh:8b", title: "saltmarsh:8b", size: 15 * gib, expires: now.addingTimeInterval(900)), tone: 1),
        ]
        let meter = RunnersMeter.model(two, memory: memory, now: now, most: 7)
        check("the headline: 61 GB of 512 GB", close(meter.number, 61) && meter.caption == "of 512 GB held by models" && meter.capacity == Double(512 * gib), [meter.number, meter.caption])
        check("its status line", meter.status == .plain("Two models loaded, 61 GB; 398 GB free"), meter.status)
        check("its bar: one segment a model, then everything else", meter.segments.map(\.id) == ["ollama|harbor:70b", "ollama|saltmarsh:8b", "others"] && meter.segments.map(\.value) == [Double(46 * gib), Double(15 * gib), Double(53 * gib)], meter.segments.map(\.value))
        if case .suggestion(_, _, let text, _) = meter.footer {
            check("its footer names the next to unload", text == "harbor:70b unloads in 4 min and frees 46 GB unless something asks for it first.", text)
        } else {
            check("its footer names the next to unload", false, meter.footer.key)
        }
        check("with nothing loaded", RunnersMeter.model(RunnersModel.Picture(runners: two.runners), memory: memory, now: now, most: 7).status == .plain("No models loaded; 398 GB free"))
        var many = two
        many.loaded = (0..<10).map { RunnersModel.Loaded(model: RunnerModel(runner: .ollama, name: "m\($0)", title: "m\($0)", size: UInt64(10 - $0) * gib), tone: $0) }
        let crowded = RunnersMeter.model(many, memory: memory, now: now, most: 7)
        check("more models than the legend holds: the smallest share an entry, and nothing is lost", crowded.items.count == 9 && crowded.items[6].name == "4 smaller models" && crowded.segments.dropLast().map(\.value).reduce(0, +) == Double(55 * gib), crowded.items.map(\.name))
        check("the page's subtitle", RunnersPage.subtitle(nil) == "Looking for runners" && RunnersPage.subtitle(RunnersModel.Picture()) == "No runner found" && RunnersPage.subtitle(two) == "Ollama 0.15.4 · 2 loaded" && RunnersPage.subtitle(picture) == "3 runners · 3 loaded · 6 on disk", RunnersPage.subtitle(picture))
        let explained = RunnersModel.explain(two, speeds: ["ollama|harbor:70b": .done(RunnerSpeedResult(tokensPerSecond: 48.5, firstToken: 0.25, tokens: 48))], memory: memory, now: now) ?? ""
        check("Explain is told what is loaded and what it holds", explained.contains("harbor:70b on Ollama: holds 46 GB, unloads in 4 min, last speed test 48.5 tokens/s · first token in 250 ms") && explained.contains("Loaded models hold 61 GB together of this Mac's 512 GB, with 398 GB free") && explained.contains("its 2 processes hold 20 GB"), explained)
        check("and when there is no runner", RunnersModel.explain(RunnersModel.Picture(), speeds: [:], memory: memory, now: now)?.contains("no model runner was found") == true)
        let demo = RunnersDemo.picture("1", since: now)
        check("the made-up page has runners, loaded models and models on disk", demo.runners.count == 3 && demo.loaded.count == 5 && demo.installed.count == 12 && RunnersDemo.picture("empty", since: now) == RunnersModel.Picture())
        if models.runners.demo == nil {
            check("the sidebar says nothing before the runners have been asked", models.runners.sidebarValue == "")
        } else {
            check("the sidebar counts the made-up models", models.runners.sidebarValue == "5 loaded", models.runners.sidebarValue)
        }

        // A stand-in, when one is named: read it, and time a model on it. Never a real runner.
        let endpoints = models.runners.endpoints
        if endpoints.standIns.contains("ollama"), let base = endpoints.ollama {
            let reading = await RunnerReader.ollama(base: base, installed: true, version: true)
            check("stand-in Ollama: read", reading.answered && reading.version != nil && !reading.loaded.isEmpty && reading.installed?.isEmpty == false, reading)
            if let first = reading.loaded.first {
                let outcome = await RunnerSpeed.measure(first, base: base, variant: nil)
                if case .done(let result) = outcome { check("stand-in Ollama: timed \(first.name) at \(result.text)", result.tokensPerSecond > 0 && result.firstToken != nil) } else { check("stand-in Ollama: timed", false, outcome) }
                var gone = first
                gone.name = "not-loaded:1b"
                check("stand-in Ollama: a model that is not loaded is not sent a prompt", await RunnerSpeed.measure(gone, base: base, variant: nil) == RunnerSpeed.unloaded)
            }
        }
        if endpoints.standIns.contains("lmStudio"), let base = endpoints.lmStudio {
            let reading = await RunnerReader.lmStudio(base: base, variant: nil)
            check("stand-in LM Studio: read through \(reading.variant ?? "nothing")", reading.answered && reading.installed?.isEmpty == false, reading)
            if let first = reading.loaded.first {
                let outcome = await RunnerSpeed.measure(first, base: base, variant: reading.variant)
                if case .done(let result) = outcome { check("stand-in LM Studio: timed \(first.title) at \(result.text)", result.tokensPerSecond > 0) } else { check("stand-in LM Studio: timed", false, outcome) }
                var gone = first
                gone.name = "not/loaded"
                check("stand-in LM Studio: a model that is not loaded is not sent a prompt", await RunnerSpeed.measure(gone, base: base, variant: reading.variant) == RunnerSpeed.unloaded)
            }
        }
        if endpoints.standIns.contains("local"), let base = endpoints.local, base.port != 0 {
            let found = await RunnerReader.local(base: base, mlx: (endpoints.localKind == .mlx, endpoints.localModel), known: nil)
            check("stand-in server: recognised as \(found?.reading.kind.title ?? "nothing")", found?.reading.answered == true, found as Any)
            if let first = found?.reading.loaded.first {
                let outcome = await RunnerSpeed.measure(first, base: base, variant: nil)
                if case .done(let result) = outcome { check("stand-in server: timed \(first.title) at \(result.text)", result.tokensPerSecond > 0 && result.firstToken != nil) } else { check("stand-in server: timed", false, outcome) }
            }
            let stranger = await RunnerReader.local(base: base, mlx: (false, nil), known: nil)
            if found?.reading.kind == .mlx {
                check("a server that does not say what it is, with no process to say so, is left alone", stranger == nil, stranger as Any)
            } else {
                check("llama.cpp's server needs no process to be known", stranger?.reading.kind == .llamaCpp, stranger as Any)
            }
        }
        // And nothing answers on a port nobody listens on: quickly, and as silence.
        let started = Date()
        let nobody = await RunnerReader.ollama(base: RunnerEndpoints.local(port: 9), installed: true, version: true)
        check("a port that refuses is silence, in \(Int(Date().timeIntervalSince(started) * 1000)) ms", !nobody.answered && Date().timeIntervalSince(started) < 1.6, nobody)

        print(failed == 0 ? "all \(passed) checks pass" : "\(failed) FAILED of \(passed + failed)")
    }
}
