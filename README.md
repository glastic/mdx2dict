# mdx2dict

Convert MDict (`.mdx`) dictionaries into macOS Dictionary.app bundles using
Apple's Dictionary Development Kit.

The core is dictionary-agnostic: it parses MDX/MDD, extracts text, images and
audio, rewrites internal links, and generates Apple Dictionary XML. Any
dictionary-specific styling is supplied externally through CSS, not hard-coded
in the converter.

## Features

- MDict 2.x parsing: zlib, UTF-8 / UTF-16LE, Encrypted bit 1 (key-index
  encryption), `@@@LINK` redirects.
- `@@@LINK=` is a widely used MDX convention (not part of the binary format) for
  aliases; aliases and inflected forms are merged into the target entry index.
- Apple Dictionary XML generation and `build_dict.sh` integration.
- Original dictionary CSS is auto-detected and used as the base stylesheet.
- Internal `entry://` links rewritten to `x-dictionary:r:<entry-id>`.
- Optional thumbnail/full image extraction from `.mdd`.
- Optional audio extraction from `.mdd`, rewritten as
  `javascript:new Audio("audio/...mp3").play();` (works in Dictionary.app).
- `@@@LINK` aliases and inflected forms are merged into the target entry's
  index, so lookups such as plurals or past tenses resolve.
- Parallel entry sanitization and parallel resource extraction.
- Streaming full conversion: entries are read, sanitized and written in
  batches, so peak memory stays bounded for large dictionaries.
- Progress reporting with elapsed time and ETA.
- Optional work-directory cleanup with `--clean`.

## Requirements

| Requirement | Notes |
|---|---|
| macOS 13+ | Build and runtime target |
| Xcode / Command Line Tools | Needed only to compile |
| Dictionary Development Kit | Required; from Apple *Additional Tools for Xcode* |

The DDK is not bundled or redistributed. The tool locates it automatically at
`/Applications/Utilities/Dictionary Development Kit`, or via:

```bash
export MDX2DICT_DDK="/path/to/Dictionary Development Kit"
# or
mdx2dict convert ... --ddk "/path/to/Dictionary Development Kit"
```

## Build

```bash
swift build -c release
swift test
```

The executable is `.build/release/mdx2dict`.

## Usage

```bash
# Check environment
.build/release/mdx2dict doctor

# Convert the first 100 entries
.build/release/mdx2dict convert ./dictionary.mdx \
  --limit 100 \
  --name "My Dictionary" \
  --install

# Convert selected words
.build/release/mdx2dict convert ./dictionary.mdx \
  --words hello,run,look \
  --images thumb \
  --install

# Full conversion with thumbnails and audio
.build/release/mdx2dict convert ./dictionary.mdx \
  --limit 0 \
  --images thumb \
  --audio all \
  --audio-exclude 'example|sentence' \
  --name "My Dictionary" \
  --install \
  --clean
```

### Options

| Option | Description |
|---|---|
| `--limit N` | Export first N unique entries; `0` = all (default 100) |
| `--words LIST` | Export only comma-separated words (overrides `--limit`) |
| `--name NAME` | Dictionary display name (default: MDX title) |
| `--css PATH` | Base CSS (default: auto-detect a `.css` next to the MDX) |
| `--css-extra PATH` | Extra CSS appended after the generic overrides |
| `--images MODE` | `none` (default), `thumb`, or `all` |
| `--audio MODE` | `none` (default) or `all` |
| `--audio-exclude REGEX` | Skip audio whose key or class matches the regex |
| `--jobs N` | Parallelism: `0` auto, `1` serial (default 0) |
| `--resources MODE` | Missing-resource policy: `skip`, `drop`, `strict` (default `skip`) |
| `--out DIR` | Work directory (default `./build`) |
| `--ddk PATH` | Dictionary Development Kit path |
| `--install` | Copy the bundle into `~/Library/Dictionaries` |
| `--clean` | Delete this run's work directory after success |
| `--quiet` | Reduce output |

After installation, enable the dictionary in **Dictionary.app → Settings**.

### Work directory

By default the timestamped work directory is kept for inspection. With
`--clean`, it is removed after a successful build; if `--install` was not used,
the built `.dictionary` is first moved to `--out` so the product survives.
Failed builds keep the work directory for debugging.

### Images

- `none`: remove all `<img>` elements.
- `thumb`: keep images whose class or filename contains `thumb`, skip ones
  containing `fullsize`. This is a naming heuristic; use `all` if your
  dictionary does not follow it.
- `all`: keep every referenced image.

Images are written directly into the final bundle's `Contents/Resources/`.

### Audio

`--audio all` extracts every `sound://` resource referenced by an entry and
rewrites the link to an inline `new Audio(...)` call. Use
`--audio-exclude REGEX` to filter example/sentence audio, for example:

```bash
--audio-exclude 'example|sentence'
```

Audio is written to `Contents/Resources/audio/`. Playback works in the full
Dictionary.app window; the lightweight Look Up popover does not provide audio
playback controls.

### Missing resources

Sometimes an entry references an image or audio key that is absent from the
`.mdd` files. Choose how to handle that:

| Mode | Behavior |
|---|---|
| `skip` (default) | Do not check existence. Missing keys are counted as `skipped` during extraction, but the generated HTML still references them. Fastest, but may leave broken images or silent audio buttons. |
| `drop` | Check existence via the MDict key index. Missing image/audio references are removed from the HTML, and the count is reported. Output contains no dead references. |
| `strict` | Same check, but abort the conversion if anything is missing. The error lists the missing keys. Useful in CI or before publishing. |

The existence check only reads the key index, not the image/audio payload, so
`drop`/`strict` are inexpensive compared with a second full resource read.
`strict` fails before the DDK build; the work directory is kept for inspection.

### CSS

The base stylesheet is auto-detected from the MDX directory. The converter then
appends a small set of generic overrides (content width, image sizing, audio
button styling, system dark-mode background). It does **not** contain any
dictionary-specific selectors.

For per-dictionary tuning, pass an extra stylesheet:

```bash
.build/release/mdx2dict convert ./dictionary.mdx \
  --css-extra ./examples/overrides.css
```

A starting point is provided in [`examples/overrides.css`](examples/overrides.css).
It expands common collapsed blocks, adjusts bilingual spacing, and adds a
dark-mode fallback.

This is the intended place for rules that expand collapsed sections, adjust
bilingual spacing, or customize dark-mode colors for a particular dictionary.

### Troubleshooting

| Symptom | Fix |
|---|---|
| `Dictionary Development Kit not found` | Install Apple *Additional Tools for Xcode*, then pass `--ddk` or set `MDX2DICT_DDK` |
| Dictionary not visible in Dictionary.app | Open **Dictionary → Settings** and enable it |
| No audio in the three-finger Look Up popover | Open the entry in the full Dictionary.app window; the popover does not provide audio controls |
| Collapsed sections stay hidden | Add the expansion rules from `examples/overrides.css` via `--css-extra` |
| `--clean` removed the build but I wanted the XML | Omit `--clean`; the timestamped work directory is kept by default |

## How it works

```text
.mdx
  └─ MDict parser (zlib / encryption / @@LINK)
       └─ entry HTML
            └─ libxml2 HTML parser (preserves custom tags and CSS structure)
                 └─ sanitizer (remove scripts/unsafe links, rewrite entry://)
                      ├─ image store  → Contents/Resources/
                      ├─ audio store  → Contents/Resources/audio/
                      └─ Apple Dictionary XML (<d:entry> + <d:index>)
                           └─ build_dict.sh -v 10.11
                                └─ Name.dictionary
                                     └─ ~/Library/Dictionaries
```

`Sources/CXML2` is a small libxml2 shim used to serialize HTML `<body>`
children as XML while preserving custom elements.

## Performance

Reference numbers for a 1,200-entry conversion with thumbnails (no audio) on an
Apple-silicon Mac:

| Stage | Time |
|---|---:|
| collect entries | ~0.2s |
| sanitize (parallel) | ~0.7s |
| XML writing | ~0.1s |
| DDK build | ~3.5s |
| resources | ~0.1s |
| **total** | **~5s** |

Audio and full builds are dominated by DDK build time and resource I/O; both
sanitization and resource extraction run in parallel.

Full conversion is streamed in batches. For a ~70k-entry dictionary, peak RSS
stays around 1.3 GB while the XML is written incrementally; the DDK build
dominates wall-clock time.

## Limitations

- MDict 2.x only; MDict 3.x and LZO-compressed files are rejected.
- Encrypted bit 1 is supported; password/RegCode-encrypted files are not.
- JavaScript from the original dictionary is not executed; only the generated
  audio playback snippets are emitted.
- Images/audio depend on resource keys being referenced by the entry HTML.
- Complex layouts may need a dictionary-specific `--css-extra`.
- Dictionary Development Kit is Apple-proprietary and must be installed by the
  user; it is not redistributed with this project.

## Directory

```text
Sources/
├── CXML2/            # libxml2 HTML → XML shim
└── mdx2dict/
    ├── MDict/        # MDict parser
    ├── DDK.swift     # locate and invoke build_dict.sh
    ├── HTMLSanitizer.swift
    ├── Converter.swift
    ├── Errors.swift
    └── main.swift
```

## License

MIT. See [LICENSE](LICENSE).

### Third-party components and content

- The Dictionary Development Kit is Apple-proprietary. It is not bundled or
  redistributed; users must install it themselves.
- Dictionary files and their images/audio may be copyrighted. Only convert
  dictionaries you have the right to use, and do not redistribute converted
  content.
- The MDict parser in `Sources/mdx2dict/MDict` is maintained as part of this
  project. If you incorporate third-party code, add the corresponding notice.
