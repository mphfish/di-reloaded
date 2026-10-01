# DI Reloaded — Project Plan

A spiritual successor to Disk Inventory X, lovingly vibe coded: a from-scratch, native
Swift treemap disk usage explorer for current macOS. It shares no code with the original.

**Requirements**
1. Distributed through GitHub Releases
2. Current native macOS look (Liquid Glass on macOS 26)
3. As fast as possible: scanning, layout, rendering, and interaction

**Toolchain:** Xcode 26.6, Swift 6.3, macOS 26.5 SDK.

---

## 1. Scope

### Parity with Disk Inventory X (v1.0)
- Pick a volume or folder and scan it, with live progress
- **Cushion treemap** of the whole tree; hovering shows the path and size; clicking selects
- **Outline view** of folders and files sorted by size, with selection kept in sync with the treemap
- **Kind statistics** sidebar: totals by file type, each with a color that matches the treemap. Selecting a kind highlights it in the treemap.
- Zoom into or out of a folder in the treemap
- Reveal in Finder, Quick Look, Move to Trash (then update the tree in place without a rescan)
- Show or hide package contents (.app, .photoslibrary, etc.)
- Show free space and "other/unscanned" space as their own blocks

### Additions (v1.x)
- Incremental refresh through FSEvents, so you don't rescan after deleting
- Rescan only the selected subtree
- Search and filter by name, kind, size, or date
- Export a scan to CSV/JSON
- Open multiple scans in separate windows or tabs

### Out of scope
- Cloud storage provider internals (files that are only placeholders count at their local size)
- Duplicate-file finding (possible later)
- Windows and Linux

---

## 2. Architecture

```
DIReloaded.app  (SwiftUI app shell + AppKit where performance needs it)
├── ScanKit        – filesystem enumeration, tree storage, kind classification
├── TreemapKit     – squarified layout (pure Swift, no UI)
├── TreemapView    – Metal renderer + hit testing (AppKit NSView / MTKView)
└── App            – windows, outline, sidebar, toolbar, settings, updates
```

All the core logic lives in a local Swift package (`Packages/Core`), so it can be
unit-tested and benchmarked without the app. Swift 6 strict concurrency is on from the start.

### 2.1 Scanner (ScanKit): where most of the speed comes from
- **Use `getattrlistbulk(2)` instead of `FileManager` or `fts`.** It returns name, object
  type, file ID, link count, logical size, and allocated size for many entries in one
  syscall. It's the fastest userspace way to walk APFS. A thin C shim inside the package
  handles the attribute-buffer parsing.
- **Parallel traversal.** Use a bounded work queue of directory file descriptors drained by
  roughly `activeProcessorCount` workers (threads, not one Task per directory, to keep
  scheduling overhead down). Open children with `openat()` relative to the parent fd so the
  kernel never resolves full paths.
- **Correct accounting:**
  - Default to *allocated* size, which is what's actually on disk. Logical size is a toggle.
  - Count hard links once, deduplicated by `(dev, fileID)` when `linkcount > 1`.
  - Stay on one device: don't cross mount points unless the user asks.
  - Handle APFS firmlinks so `/` and `/System/Volumes/Data` aren't counted twice.
  - Known limitation: APFS clones and snapshots share blocks, and userspace can't
    attribute that exactly. Explain this in the UI rather than show a wrong number.
- **Progressive results.** Stream partial totals to the UI every ~100 ms so the treemap
  fills in while the scan runs.
- **Cancellation** at every directory boundary.

### 2.2 Tree storage: built for memory and cache efficiency
Big disks hold 2–10M+ files. One Swift class per node would cost about 100+ bytes each
plus ARC traffic. Instead, use a **flat arena**:

```swift
struct NodeStore {            // struct-of-arrays, indices are UInt32
  var parent:     [UInt32]
  var firstChild: [UInt32]
  var nextSibling:[UInt32]
  var size:       [UInt64]    // subtree total for dirs
  var nameRange:  [UInt64]    // offset/len into one shared UTF-8 byte buffer
  var kind:       [UInt16]    // index into kind table
  var flags:      [UInt8]     // dir, package, hardlink, etc.
}
```
- About 35–40 bytes per node, so 10M files is roughly 400 MB.
- Each worker builds into its own local arena; the arenas are merged at the end, so the hot
  path takes no locks.
- Children are sorted by size once, after the scan.
- Full paths are rebuilt on demand by walking `parent`.

### 2.3 Kind classification
- Map extension → UTType once per *unique extension*, never once per file, and cache the
  result. Group by UTType conformance (image, movie, audio, archive, code, app, …).
- Use a stable, accessible palette that adapts to light and dark mode. Users can override
  colors.

### 2.4 Treemap layout (TreemapKit)
- **Squarified treemap** (Bruls, Huizing, van Wijk) on the size-sorted children.
- **Stop recursing below about 1 px².** Detail you can't see isn't laid out, so layout cost
  depends on window size, not file count.
- Layout runs off the main thread and is redone on resize (debounced) and on zoom.
- Output is a flat array of `(rect, depth, nodeIndex, colorIndex)` that goes straight into a
  GPU buffer.

### 2.5 Rendering (TreemapView)
- **Metal**, one instanced draw call per frame. Each rectangle is an instance.
- Do the **cushion shading** (van Wijk & van de Wetering) in the fragment shader: pass the
  per-rect cushion coefficients as instance data. This keeps DIX's classic look at 120 Hz.
- Draw hover and selection highlights as a separate overlay pass, so moving the mouse never
  triggers a re-layout.
- **Hit testing:** walk the layout from the root down, which is O(depth), or use a coarse
  spatial grid.
- If Metal adds too much complexity early on, the fallback is Core Graphics into a
  `CGContext` bitmap cache. Either way the renderer sits behind a protocol so it can be
  swapped.

### 2.6 UI (App)
- **SwiftUI shell:** `NavigationSplitView` with a sidebar for volumes and kinds, a content
  area for the treemap, and the outline in a split or inspector. Toolbar, `.searchable`,
  Settings scene, and menu commands.
- **Outline:** an `NSOutlineView` wrapped in `NSViewRepresentable`. It's virtualized and
  proven with millions of lazily loaded rows; SwiftUI `List`/`OutlineGroup` isn't reliable
  at that scale.
- **Native visuals:** building with the macOS 26 SDK gives standard controls Liquid Glass
  automatically. Use `.glassEffect` and toolbar/sidebar materials where they fit. SF
  Symbols, an app icon made with Icon Composer, full dark mode and accessibility (VoiceOver
  labels on treemap regions, Reduce Transparency, Increase Contrast).
- **Volumes list** from `FileManager.mountedVolumeURLs` + `URLResourceValues` (capacity,
  available, "important usage" capacity), with live mount/unmount through `NSWorkspace`
  notifications.

### 2.7 Permissions
- The app is **not sandboxed**. A disk inventory tool needs to read everywhere, and
  sandboxing gains nothing outside the App Store.
- **Full Disk Access** can't be requested from code. Detect when it's missing by probing a
  protected path such as `~/Library/Mail` and show an onboarding card with a deep link
  (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`).
- Without FDA the scan still runs. Protected folders show as "inaccessible" with their count.

---

## 3. Distribution (GitHub Releases)

| Piece | Choice |
|---|---|
| Signing | Developer ID Application certificate + Hardened Runtime |
| Notarization | `xcrun notarytool submit --wait`, then `xcrun stapler staple` |
| Package | Signed, notarized `.dmg` (via `create-dmg` or `hdiutil`), plus a `.zip` for Sparkle |
| CI | GitHub Actions on a `macos-26` runner. Pushing a `v*` tag builds, signs, notarizes, and creates the release |
| Secrets | Certificate `.p12` + password, App Store Connect API key for notarytool, Sparkle EdDSA private key |
| Auto-update | **Sparkle 2**, with `appcast.xml` generated by `generate_appcast` and hosted on GitHub Pages or as a release asset |
| Extras | Homebrew cask (`brew install --cask di-reloaded`) once it's stable |
| Architecture | Universal binary (arm64 + x86_64), since macOS 15 still runs on Intel Macs |

> Requires the Apple Developer Program membership (confirmed available).

---

## 4. Performance budget and benchmarking

Speed is a requirement, so it gets measured from week one.

- **Benchmark harness:** a CLI target (`dir-bench`) that runs ScanKit against a path and
  reports files/sec, wall time, and peak RSS.
- **Baselines:** `du -sk`, plus Finder's own size calculation, on the same trees. Run warm
  cache and cold cache (after `purge`) separately.
- **Fixtures:** a generated synthetic tree (1M files, deep and wide variants) for repeatable
  CI numbers, plus real runs on `/` and `~`.
- **Targets** are set after the Phase 0 spike measures real numbers. The working goal: scan
  faster than `du`, keep treemap interaction at 120 fps, render the first treemap in
  under 1 s, and stay under 50 bytes per node.
- Profile with Instruments (Time Profiler, Allocations, Metal System Trace). The CI benchmark
  job flags regressions above 10%.

---

## 5. Phases

### Phase 0: Spike (≈1 week)
- `getattrlistbulk` scanner prototype + `dir-bench`; compare with `du` and `FileManager`
- Squarified layout + Core Graphics rendering in a throwaway window
- **Exit:** measured numbers, final memory layout, Metal vs. CG decision

**Phase 0 results (2026-10-01, M5, 10 cores, macOS 26.5, home folder: ~1M entries, 122 GB)**

| Measurement | Result |
|---|---|
| ScanKit scan (6 threads) | **3.1–4.0 s** (~250–325k entries/s) |
| `du -sk` | 12.9 s (ScanKit is ~3.2× faster; totals match to the KB) |
| FileManager enumerator | 14.9 s |
| Tree assembly | 35 ms (negligible) |
| Tree memory | 56 bytes/entry, names included; peak RSS 177 MB |
| Squarified layout, 1600×1000 | **1.9 ms** for 123k rectangles |
| CPU cushion render + PNG | ~90 ms |

Findings:
- **The scan is limited by SSD latency, not CPU.** User CPU is ~0.2 s. The kernel's vnode
  cache (`kern.maxvnodes` = 263k) is smaller than the tree, so even "warm" scans make
  ~130k random 4 KB metadata reads (30–45k IOPS). Threads help up to about 4–6; past that,
  APFS lock contention makes the scan slower. **The default is now `min(cores, 6)`.**
- Opening children with `openat()` relative to an open parent fd made no measurable
  difference, so it was reverted to keep the code simple.
- **Decision: use Metal.** Layout is cheap enough to redo on every frame of a live resize,
  but a CPU repaint (~90 ms) can't reach 120 fps.
- The arena layout is final. It's slightly over the 50 bytes/entry target, mostly because of
  names. Possible later savings: shared prefixes, or 48-bit size fields.
- Still to do: tune the cushion shading (currently darker than DIX's), add kind-based colors,
  and benchmark a cold cache (`sudo purge`) and the whole `/` volume.

### Phase 1: Core engine (≈2 weeks)
- ✅ ScanKit: parallel scanner, arena store, hard link and firmlink handling, cancellation
- ✅ Kind classification. UTType is looked up once per unique extension, kinds that share a
  type are merged (.jpg/.jpeg), and kinds are ranked by total size. Packages (.app etc.) are
  flagged. Cost: ~35 ms per 1M entries.
- ✅ TreemapKit layout with pixel cutoff
- ✅ Unit tests (synthetic trees with known sizes), plus a CI benchmark check against `du`
  on the same runner (`scripts/bench-check.sh`, which fails above 0.6× of du's time)
- ⏩ Progressive results (a partial tree while scanning) moved to Phase 2, where the UI
  that consumes them gets built
- ⏳ Cold-cache benchmark (needs `sudo purge`)

**Phase 1 measurements (M5)**

| Tree | Entries | ScanKit | Notes |
|---|---|---|---|
| Whole disk `/` | 2.15M | **8.1 s** | 53 bytes/entry, peak RSS 357 MB, layout 2.1 ms |
| Data volume | 1.67M | 5.3 s | Same total as via `/`, so the firmlink handling loses nothing |
| Fixture, 200k files, fully cached | 210k | 0.13 s | 0.40× of `du` |

**Finding: the scan finds 291 GB, but `df` reports ~440 GB used.** Scanning without root
leaves 408 directories unreadable: `/private` (root-only system data) and protected parts
of `~/Library`. Sealed system snapshots and purgeable space also count toward used space
in ways userspace can't attribute. This makes two features matter more:
- **"Unaccounted space" block** (used minus scanned) in the treemap, with an explanation
  (Phase 2)
- **Scan as administrator**: an optional privileged helper via `SMAppService` that scans as
  root (v1.x)

### Phase 2: MVP app (≈2–3 weeks)
- ✅ Volume picker and Open Folder; scan progress with a **live breakdown by top-level
  folder** (atomic per-folder counters, no partial tree needed) and a hint when a privacy
  prompt is blocking the scan
- ✅ Metal treemap with hover, select, zoom, kind highlighting and context menus
- ✅ NSOutlineView synced with treemap selection in both directions
- ✅ Kinds sidebar with highlighting; free and unaccounted space blocks
- ✅ Show in Finder, Quick Look, Copy Path, Move to Trash with in-place tree update
- ✅ Full Disk Access onboarding; folder usage descriptions in Info.plist
- ✅ Fixed: `HSplitView` misplaced the file list inside the macOS 26 split view, so it
  was replaced with a SwiftUI split
- ⏩ **Treemap visual redesign** moved to Phase 4. The cushion shading inherited from DIX
  looks dated and will be replaced with a modern look rather than tuned.

### Phase 3: Distribution pipeline (≈1 week, can run alongside Phase 2)
- Signing, notarization, DMG, GitHub Actions release workflow
- Sparkle integration + appcast
- First `v0.1.0` pre-release on GitHub

### Phase 4: Polish and v1.0 (≈2 weeks)
- **Modern treemap visuals** replacing the DIX-style cushions (flat or rounded tiles,
  system colors, labels on large tiles, light and dark mode)
- Liquid Glass and visual polish, app icon, settings (colors, logical vs. allocated size,
  package handling)
- Accessibility pass, localization scaffolding
- Performance pass against the budget
- README with screenshots, Homebrew cask
- **v1.0.0 release**

### Phase 5: v1.x
- FSEvents incremental refresh, subtree rescan, search/filter, export, multiple windows

---

## 6. Repository layout

```
diskinventoryreloaded/
├── App/                          # Xcode app target (SwiftUI + AppKit)
├── Packages/Core/
│   ├── Sources/CBulkAttr/        # C shim for getattrlistbulk
│   ├── Sources/ScanKit/
│   ├── Sources/TreemapKit/
│   ├── Sources/TreemapView/      # Metal renderer + shaders
│   ├── Sources/dir-bench/
│   └── Tests/
├── scripts/                      # make-dmg.sh, notarize.sh, gen-fixtures.sh
├── .github/workflows/            # ci.yml (build+test+bench), release.yml
└── PLAN.md
```

---

## 7. Decisions

| Decision | Outcome |
|---|---|
| Apple Developer account | ✅ Available, so Developer ID signing + notarization are in from v0.1.0 |
| Minimum macOS | ✅ **macOS 15+**, built with the macOS 26 SDK (Liquid Glass on 26), shipped as a universal binary (arm64 + x86_64) |
| License | ✅ **MIT** |
| Name & icon | ✅ **DI Reloaded** (bundle `DIReloaded.app`), a spiritual successor. New icon, no DIX branding |

## 8. Risks
| Risk | Mitigation |
|---|---|
| `getattrlistbulk` parsing edge cases (variable-length attributes, odd filesystems like SMB/exFAT) | Fall back to `fts` for non-APFS/HFS+ volumes; fuzz with fixtures |
| Memory on very large or networked volumes | Arena store; optional "collapse below N bytes" mode |
| APFS clone/snapshot sizes confuse users | Show volume "used" vs. "scanned" gap as an explicit "other" block with an explanation |
| Metal renderer complexity | CG fallback behind a protocol (decided in Phase 0) |
| Notarization/CI secret handling | Document setup; use the App Store Connect API key rather than an Apple ID password |
