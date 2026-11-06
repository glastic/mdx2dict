import Foundation

struct DDK {
    let root: URL

    var buildScript: URL {
        root.appendingPathComponent("bin/build_dict.sh")
    }

    static let requiredTools = [
        "/usr/bin/xmllint",
        "/usr/bin/plutil",
        "/usr/bin/xsltproc",
        "/usr/bin/perl"
    ]

    /// 显式参数或环境变量提供时只使用该路径；只有都未提供时才搜索默认位置。
    static func locate(explicit: String?) -> DDK? {
        if let explicit, !explicit.isEmpty {
            return locateSingle(explicit)
        }
        if let env = ProcessInfo.processInfo.environment["MDX2DICT_DDK"], !env.isEmpty {
            return locateSingle(env)
        }
        for candidate in defaultPaths {
            if let ddk = locateSingle(candidate) {
                return ddk
            }
        }
        return nil
    }

    private static let defaultPaths = [
        "/Applications/Utilities/Dictionary Development Kit",
        NSHomeDirectory() + "/Applications/Dictionary Development Kit"
    ]

    private static func locateSingle(_ path: String) -> DDK? {
        let root = normalize(path)
        let script = root.appendingPathComponent("bin/build_dict.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            return nil
        }
        return DDK(root: root)
    }

    /// 允许用户传 DDK 根目录、bin 目录或 build_dict.sh 本身。
    private static func normalize(_ path: String) -> URL {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if url.lastPathComponent == "build_dict.sh" {
            url = url.deletingLastPathComponent().deletingLastPathComponent()
        } else if url.lastPathComponent == "bin" {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// 调用 DDK，返回生成的 .dictionary 路径。
    func build(workDir: URL, name: String) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            buildScript.path,
            "-v", "10.11",
            name,
            "dict.xml",
            "style.css",
            "Info.plist"
        ]
        process.currentDirectoryURL = workDir

        var env = ProcessInfo.processInfo.environment
        env["DICT_DEV_KIT_OBJ_DIR"] = "objects"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        // 合并 stdout/stderr，避免两个 pipe 互相阻塞。
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        let logData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let log = String(decoding: logData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Mdx2DictError.ddkFailed(status: process.terminationStatus, log: log)
        }

        let output = workDir
            .appendingPathComponent("objects", isDirectory: true)
            .appendingPathComponent("\(name).dictionary", isDirectory: true)
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw Mdx2DictError.ddkFailed(
                status: 0,
                log: log + "\nDDK finished but output was not found: \(output.path)"
            )
        }
        return output
    }
}
