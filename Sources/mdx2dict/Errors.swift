import Foundation

enum Mdx2DictError: Error, CustomStringConvertible {
    case usage(String)
    case badOption(String)
    case invalidOption(String)
    case ddkNotFound
    case missingTool(String)
    case ddkFailed(status: Int32, log: String)
    case installFailed(String)
    case missingResources([String])

    var description: String {
        switch self {
        case let .usage(text):
            return text
        case let .badOption(name):
            return "unknown option: \(name)"
        case let .invalidOption(message):
            return "invalid option: \(message)"
        case .ddkNotFound:
            return """
            Dictionary Development Kit not found.
            Install "Additional Tools for Xcode", then pass --ddk <path> or set MDX2DICT_DDK.
            Expected default: /Applications/Utilities/Dictionary Development Kit
            """
        case let .missingTool(path):
            return "required system tool is missing or not executable: \(path)"
        case let .ddkFailed(status, log):
            return "build_dict.sh failed (exit \(status)):\n\(log)"
        case let .installFailed(reason):
            return "install failed: \(reason)"
        case let .missingResources(keys):
            let sample = keys.prefix(20).joined(separator: ", ")
            let suffix = keys.count > 20 ? " ..." : ""
            return "missing \(keys.count) resource(s): \(sample)\(suffix)"
        }
    }
}

/// 用于在 forEachEntry 中提前停止遍历的内部信号。
struct StopIteration: Error {}
