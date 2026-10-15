import Foundation

/// Upstream EJS 0.8.0 AST solver, executed inside the existing system JavaScriptCore.
/// No subprocess, Node/Deno, Python or yt-dlp runtime is used.
enum NativeEJSSolver {
    static let script: String? = {
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("Videx_Videx.bundle")) } ?? Bundle.module
        guard let lib = bundle.url(forResource: "ejs-lib.min", withExtension: "js", subdirectory: "Resources"),
              let core = bundle.url(forResource: "ejs-core.min", withExtension: "js", subdirectory: "Resources"),
              let libCode = try? String(contentsOf: lib, encoding: .utf8),
              let coreCode = try? String(contentsOf: core, encoding: .utf8) else { return nil }
        return libCode + "\nObject.assign(globalThis, lib);\n" + coreCode
    }()

    static func solve(player: String, channel: String, inputs: [String], runtime: JSRuntime) throws -> [String: String] {
        guard let script else { throw ExtractionError.jsFailure("内置 EJS 脚本资源缺失") }
        let request: [String: Any] = ["type": "player", "player": player, "output_preprocessed": false,
                                    "requests": [["type": channel, "challenges": inputs]]]
        let data = try JSONSerialization.data(withJSONObject: request)
        let expression = "JSON.stringify(jsc(\(String(decoding: data, as: UTF8.self))))"
        let output = try runtime.evaluate(code: script, globalStubs: JSShims.browserStubs, expression: expression)
        let result = try JSON(data: Data(output.utf8))
        let response = result["responses"][0]
        guard response["type"].string == "result" else {
            throw ExtractionError.jsFailure(response["error"].string ?? result["error"].string ?? "EJS 求解失败")
        }
        return response["data"].dict?.compactMapValues(\.string) ?? [:]
    }
}
