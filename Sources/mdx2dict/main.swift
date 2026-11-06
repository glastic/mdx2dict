import Foundation

func usage() -> String {
    """
    mdx2dict — MDX → macOS Dictionary.app (Dictionary Development Kit)

    USAGE:
      mdx2dict doctor [--ddk <path>]
      mdx2dict convert <input.mdx> [options]
      mdx2dict --version

    OPTIONS:
      --limit N     只导出前 N 条唯一词条（默认 100；0 = 全部）
      --words LIST  只导出指定词（逗号分隔，优先于 --limit）
      --name NAME   生成的词典名称（默认取 MDX 标题）
      --css PATH    使用指定 CSS（默认自动找 MDX 同目录的 .css）
      --css-extra PATH  追加自定义 CSS（用于适配某本词典的版式）
      --images MODE 图片策略：none | thumb | all（默认 none）
      --audio MODE  音频策略：none | all（默认 none）
      --audio-exclude REGEX  跳过匹配该正则的音频（key 或 class）
      --jobs N      并行度：0 = 自动，1 = 串行（默认 0）
      --resources MODE  缺失资源策略：skip | drop | strict（默认 skip）
      --clean       成功后删除本次 work 目录（仅本次生成的目录）
      --out DIR     工作目录（默认 ./build）
      --ddk PATH    Dictionary Development Kit 路径
      --install     构建后复制到 ~/Library/Dictionaries
      --quiet       减少输出
      -h, --help    显示帮助

    ENV:
      MDX2DICT_DDK  Dictionary Development Kit 路径

    EXAMPLES:
      mdx2dict doctor
      mdx2dict convert ./dictionary.mdx --limit 100 --install
      mdx2dict convert ./dictionary.mdx --words hello,run --images thumb --install
      mdx2dict convert ./dictionary.mdx --limit 0 --images thumb --audio all --clean
      mdx2dict convert ./dictionary.mdx --css-extra ./overrides.css --install
    """
}

func requireOptionValue(
    _ flag: String,
    _ args: [String],
    _ index: Int
) throws -> String {
    guard index + 1 < args.count else {
        throw Mdx2DictError.invalidOption("\(flag) requires a value")
    }
    return args[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage())
    exit(2)
}
let args = Array(arguments.dropFirst())

do {
    switch command {
    case "doctor":
        var ddkPath: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--ddk":
                ddkPath = try requireOptionValue("--ddk", args, i)
                i += 2
            case "-h", "--help":
                print(usage())
                exit(0)
            default:
                throw Mdx2DictError.badOption(args[i])
            }
        }

        guard let ddk = DDK.locate(explicit: ddkPath) else {
            if let ddkPath, !ddkPath.isEmpty {
                throw Mdx2DictError.invalidOption(
                    "--ddk does not contain bin/build_dict.sh: \(ddkPath)"
                )
            }
            throw Mdx2DictError.ddkNotFound
        }
        print("DDK: \(ddk.root.path)")
        var allOK = true
        for tool in DDK.requiredTools {
            let ok = FileManager.default.isExecutableFile(atPath: tool)
            print("\(ok ? "OK     " : "MISSING") \(tool)")
            allOK = allOK && ok
        }
        guard allOK else {
            throw Mdx2DictError.missingTool("one or more system tools are missing")
        }
        print("environment OK")

    case "convert":
        var limit = 100
        var words: [String] = []
        var name: String?
        var cssPath: String?
        var cssExtra: String?
        var imagePolicy: HTMLSanitizer.ImagePolicy = .none
        var audioPolicy: HTMLSanitizer.AudioPolicy = .none
        var audioExclude: String?
        var cleanWork = false
        var jobs = 0
        var resources: ResourcePolicy = .skip
        var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build", isDirectory: true)
        var ddkPath: String?
        var install = false
        var verbose = true
        var positional: [String] = []

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--limit":
                let raw = try requireOptionValue("--limit", args, i)
                guard let value = Int(raw), value >= 0 else {
                    throw Mdx2DictError.invalidOption("--limit expects a non-negative integer")
                }
                limit = value
                i += 2
            case "--words":
                let raw = try requireOptionValue("--words", args, i)
                words = raw.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                i += 2
            case "--name":
                name = try requireOptionValue("--name", args, i)
                i += 2
            case "--css":
                cssPath = try requireOptionValue("--css", args, i)
                i += 2
            case "--css-extra":
                cssExtra = try requireOptionValue("--css-extra", args, i)
                i += 2
            case "--images":
                let raw = try requireOptionValue("--images", args, i).lowercased()
                switch raw {
                case "none": imagePolicy = .none
                case "thumb", "thumbnail": imagePolicy = .thumbnail
                case "all": imagePolicy = .all
                default:
                    throw Mdx2DictError.invalidOption("--images expects none|thumb|all")
                }
                i += 2
            case "--audio":
                let raw = try requireOptionValue("--audio", args, i).lowercased()
                switch raw {
                case "none": audioPolicy = .none
                case "all": audioPolicy = .all
                default:
                    throw Mdx2DictError.invalidOption("--audio expects none|all")
                }
                i += 2
            case "--audio-exclude":
                audioExclude = try requireOptionValue("--audio-exclude", args, i)
                i += 2
            case "--jobs":
                let raw = try requireOptionValue("--jobs", args, i)
                guard let value = Int(raw), value >= 0 else {
                    throw Mdx2DictError.invalidOption(
                        "--jobs expects a non-negative integer"
                    )
                }
                jobs = value
                i += 2
            case "--resources":
                let raw = try requireOptionValue("--resources", args, i).lowercased()
                guard let policy = ResourcePolicy(rawValue: raw) else {
                    throw Mdx2DictError.invalidOption(
                        "--resources expects skip|drop|strict"
                    )
                }
                resources = policy
                i += 2
            case "--out":
                let raw = try requireOptionValue("--out", args, i)
                outDir = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
                i += 2
            case "--ddk":
                ddkPath = try requireOptionValue("--ddk", args, i)
                i += 2
            case "--install":
                install = true
                i += 1
            case "--clean":
                cleanWork = true
                i += 1
            case "--quiet":
                verbose = false
                i += 1
            case "-h", "--help":
                print(usage())
                exit(0)
            default:
                if arg.hasPrefix("-") {
                    throw Mdx2DictError.badOption(arg)
                }
                positional.append(arg)
                i += 1
            }
        }

        guard let inputPath = positional.first else {
            throw Mdx2DictError.usage("convert needs <input.mdx>")
        }
        guard let ddk = DDK.locate(explicit: ddkPath) else {
            if let ddkPath, !ddkPath.isEmpty {
                throw Mdx2DictError.invalidOption(
                    "--ddk does not contain bin/build_dict.sh: \(ddkPath)"
                )
            }
            throw Mdx2DictError.ddkNotFound
        }

        let input = URL(
            fileURLWithPath: (inputPath as NSString).expandingTildeInPath
        )
        let converter = Converter()
        _ = try converter.run(
            ConvertOptions(
                input: input,
                limit: limit,
                name: name,
                outDir: outDir,
                ddk: ddk,
                install: install,
                verbose: verbose,
                words: words,
                cssPath: cssPath,
                cssExtra: cssExtra,
                imagePolicy: imagePolicy,
                audioPolicy: audioPolicy,
                audioExclude: audioExclude,
                cleanWork: cleanWork,
                jobs: jobs,
                resources: resources
            )
        )

    case "-h", "--help", "help":
        print(usage())

    case "--version", "version":
        print("mdx2dict 0.1.0")

    default:
        throw Mdx2DictError.usage("unknown command: \(command)\n\n\(usage())")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
