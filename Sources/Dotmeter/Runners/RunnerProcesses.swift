import Darwin
import Foundation

/// What one runner's own processes are using, from the reading the app already has. It is known even when the
/// runner's API says little, or is not answering at all.
struct RunnerProcess: Equatable {
    var memory: UInt64 = 0
    /// 1.0 is one busy core.
    var cpu = 0.0
    /// Share of the graphics cores' time, 0...1.
    var gpu = 0.0
    var count = 0
    /// The app it belongs to, for its icon and version.
    var bundlePath: String?
    /// Ports its command line names, for servers with no port of their own.
    var ports: [Int] = []
    /// The model its command line names.
    var model: String?
}

enum RunnerMatch {
    /// Which runner a process belongs to, by where it lives and what it is called. `arguments` is only asked
    /// for a Python process, the one case a name cannot settle.
    static func kind(name: String, path: String?, arguments: () -> [String]?) -> RunnerKind? {
        if let path {
            // LM Studio's engines and helpers run from its bundle or from its folder in the home directory.
            if path.contains("/LM Studio.app/") || path.contains("/.lmstudio/") { return .lmStudio }
            if path.contains("/Ollama.app/") { return .ollama }
        }
        switch name {
        case "ollama", "Ollama", "ollama_llama_server", "ollama-runner": return .ollama
        case "llmster", "LM Studio": return .lmStudio
        case "llama-server": return .llamaCpp
        case "mlx_lm.server", "mlx_lm": return .mlx
        default: break
        }
        // Its helpers ("LM Studio Helper (GPU)"), when where they live could not be read.
        if name.hasPrefix("LM Studio") { return .lmStudio }
        if name.hasPrefix("python") || name.hasPrefix("Python"), let arguments = arguments(), isMLXServer(arguments) { return .mlx }
        return nil
    }

    /// `python -m mlx_lm.server …`, `python -m mlx_lm server …`, or the `mlx_lm.server` script run by Python.
    static func isMLXServer(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            let last = (argument as NSString).lastPathComponent
            if last == "mlx_lm.server" { return true }
            if argument.hasSuffix("mlx_lm/server.py") { return true }
            if last == "mlx_lm" || last == "mlx_lm.cli", index + 1 < arguments.count, arguments[index + 1] == "server" { return true }
        }
        return false
    }

    /// `--port 8081` or `--port=8081`.
    static func port(in arguments: [String]) -> Int? {
        value(of: "--port", in: arguments).flatMap { Int($0) }.flatMap { (1...65_535).contains($0) ? $0 : nil }
    }

    /// `--model <name or path>`, or llama.cpp's `-m`.
    static func model(in arguments: [String], short: Bool) -> String? {
        value(of: "--model", in: arguments) ?? (short ? value(of: "-m", in: arguments) : nil)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// The app a path is inside, if it is inside one.
    static func bundle(of path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// Adds up each runner's processes.
    static func usage(of processes: [(process: ProcessUsage, kind: RunnerKind, arguments: [String]?)]) -> [RunnerKind: RunnerProcess] {
        var found: [RunnerKind: RunnerProcess] = [:]
        for (process, kind, arguments) in processes {
            var use = found[kind] ?? RunnerProcess()
            use.memory += process.memory
            use.cpu += process.cpu
            use.gpu += process.gpu
            use.count += 1
            if use.bundlePath == nil { use.bundlePath = bundle(of: process.path) }
            if let arguments, kind == .llamaCpp || kind == .mlx {
                if let port = port(in: arguments), !use.ports.contains(port) { use.ports.append(port) }
                if use.model == nil { use.model = model(in: arguments, short: kind == .llamaCpp) }
            }
            found[kind] = use
        }
        return found
    }
}

/// A process's command line, the way `ps` reads it. Only processes of the same user answer.
enum ProcessArguments {
    static func read(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// The block is the argument count, the program's path, padding, then the arguments, each ended by a zero.
    /// The environment follows them and is never read.
    static func parse(_ buffer: [UInt8]) -> [String]? {
        guard buffer.count > 4 else { return nil }
        let count = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
        guard count > 0, count < 4096 else { return nil }
        var index = 4
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < count, index < buffer.count {
            var end = index
            while end < buffer.count, buffer[end] != 0 { end += 1 }
            arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return arguments.count == count ? arguments : nil
    }
}
