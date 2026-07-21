# Resource Loading Crash Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the packaged Codex Monitor load running-cat frames without depending on `Bundle.module` or a development-machine `.build` path, then build and install a verified replacement application.

**Architecture:** Add a Foundation-only locator that resolves frame files from the installed app resource bundle, SwiftPM command-line layout, or direct main resources. `RunningCatAnimationView` consumes file URLs from that locator, while packaging validates the complete five-frame resource set before signing.

**Tech Stack:** Swift 6.2+, SwiftPM, XCTest, AppKit/SwiftUI, zsh DMG packaging, macOS `codesign`/`hdiutil` diagnostics.

---

### Task 1: Add a tested, non-crashing cat-frame resource locator

**Files:**
- Modify: `Package.swift`
- Create: `Tests/CodexMonitorTests/CatFrameResourceLocatorTests.swift`
- Create: `Sources/CodexMonitor/CatFrameResourceLocator.swift`
- Modify: `Sources/CodexMonitor/RunningCatIcon.swift`

- [ ] **Step 1: Register the test target and write the failing tests**

Add this target after the executable target in `Package.swift`:

```swift
.testTarget(name: "CodexMonitorTests", dependencies: ["CodexMonitor"])
```

Create tests that use a temporary directory and assert:

```swift
func testInstalledAppResourceBundleLayoutResolvesFrame()
func testSwiftPMExecutableLayoutResolvesFrame()
func testDirectMainResourceLayoutResolvesFrame()
func testMissingFrameReturnsNil()
```

Each positive test creates exactly one empty `cat-frame-2.png` under its expected layout and calls:

```swift
CatFrameResourceLocator.frameURL(
    index: 2,
    mainResourceURL: resourceURL,
    mainBundleURL: bundleURL,
    fileManager: .default
)
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter CatFrameResourceLocatorTests
```

Expected: compilation fails because `CatFrameResourceLocator` does not exist. Confirm that this is the only new failure before writing production code.

- [ ] **Step 3: Implement the minimal locator**

Create a Foundation-only internal type with this interface:

```swift
enum CatFrameResourceLocator {
    static func frameURL(
        index: Int,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL?
}
```

Treat the first two entries as bundle roots, resolve their resources through
`Bundle(url:)`, then check the direct fallback. Return the first readable regular
file:

```text
Bundle(<mainResourceURL>/CodexMonitor_CodexMonitor.bundle) / CatFrames/cat-frame-N.png
Bundle(<mainBundleURL>/CodexMonitor_CodexMonitor.bundle) / CatFrames/cat-frame-N.png
<mainResourceURL>/CatFrames/cat-frame-N.png
```

This must cover both flat Swift 6.2 resource bundles and native Swift 6.4
`Contents/Resources` bundles. Do not reference `Bundle.module`.

- [ ] **Step 4: Route the animation loader through the locator**

In `RunningCatAnimationView.loadFrames()`, replace the `Bundle.module.url(...)` call with:

```swift
guard let url = CatFrameResourceLocator.frameURL(index: index),
      let image = NSImage(contentsOf: url) else {
    return nil
}
```

Keep the existing `compactMap` behavior so missing or unreadable frames degrade to an empty animation instead of terminating the process.

- [ ] **Step 5: Run GREEN verification and commit**

Run:

```bash
swift test --filter CatFrameResourceLocatorTests
swift test
swift build -c release
git diff --check
```

Expected: four focused tests pass, the full suite passes, and the release build completes. The existing vendored Reorderable actor-isolation warning may remain; no new warning is acceptable.

Commit:

```bash
git add Package.swift Sources/CodexMonitor/CatFrameResourceLocator.swift Sources/CodexMonitor/RunningCatIcon.swift Tests/CodexMonitorTests/CatFrameResourceLocatorTests.swift
git commit -m "fix: load cat frames from packaged resources"
```

### Task 2: Harden packaging and produce an identifiable fixed build

**Files:**
- Modify: `Packaging/Info.plist`
- Modify: `scripts/package-dmg.sh`

- [ ] **Step 1: Bump the local fixed build version**

Set `CFBundleShortVersionString` to `0.3.2` and `CFBundleVersion` to `8`. Change the DMG filename in `scripts/package-dmg.sh` to `CodexMonitor-0.3.2.dmg`.

- [ ] **Step 2: Add the packaging resource invariant**

Immediately after copying `CodexMonitor_CodexMonitor.bundle` into
`Contents/Resources`, select either its flat `CatFrames` directory or native
`Contents/Resources/CatFrames` directory, then verify all five expected files
with a loop over indexes `0` through `4`. If no supported layout exists or a
file is absent, print its full path to stderr and exit nonzero before code
signing.

- [ ] **Step 3: Build, package, and inspect the application**

Run:

```bash
swift test
scripts/package-dmg.sh
shasum -a 256 dist/CodexMonitor-0.3.2.dmg
```

Mount the DMG read-only and verify:

```text
CFBundleShortVersionString = 0.3.2
CFBundleVersion = 8
Mach-O architecture = arm64
Signature = adhoc
Five CatFrames PNGs are present
```

Use `strings` on the packaged executable and confirm `RunningCatIcon` no longer has a runtime `Bundle.module` call path. An unused compiler-generated absolute resource path is acceptable only if the verified running-cat code no longer references it and clean-machine execution passes.

- [ ] **Step 4: Commit packaging changes**

Run `git diff --check`, then commit:

```bash
git add Packaging/Info.plist scripts/package-dmg.sh
git commit -m "build: validate animation resources in dmg"
```

### Task 3: Install and deeply verify the fixed application

**Files:**
- No tracked source changes expected
- Deliverable: `dist/CodexMonitor-0.3.2.dmg`

- [ ] **Step 1: Preserve a recoverable backup**

Quit any running Codex Monitor process. Copy `/Applications/Codex Monitor.app` into a timestamped directory under the task workspace `work/` before replacement. Do not modify Codex preferences or `~/.codex` data.

- [ ] **Step 2: Install the fixed app from the mounted DMG**

Use `ditto` to copy the packaged `Codex Monitor.app` over `/Applications/Codex Monitor.app`, then verify its version, signature, architecture, and five resource files again at the installed path.

- [ ] **Step 3: Exercise the original crash condition**

Record the existing count and latest timestamp of `CodexMonitor-*.ips` crash reports. Launch the installed app while this Codex task is active, wait long enough for task detection and running-cat initialization, and assert:

```text
CodexMonitor process remains alive
No newer CodexMonitor crash report appears
Installed app log contains no Bundle.module assertion
```

- [ ] **Step 4: Verify quota and Codex selection**

Confirm the direct usage endpoint still returns HTTP 200 without printing credentials, the cached or live weekly percentage is nonempty, `/opt/homebrew/bin/codex` and `/opt/homebrew/lib/node_modules/@openai/codex` remain absent, and `command -v codex` resolves to the ChatGPT-embedded binary.

- [ ] **Step 5: Copy the verified DMG to the user-facing outputs directory**

Copy the final DMG to:

```text
/Users/lixinlv/Documents/Codex/2026-07-21/https-github-com-ys-bw-codexmonitor/outputs/CodexMonitor-0.3.2.dmg
```

Run a final SHA-256 comparison between `dist/` and `outputs/`; the hashes must match.

### Task 4: Final review and branch verification

**Files:**
- Review all changes since tag `v0.3.1`

- [ ] **Step 1: Run the complete verification matrix fresh**

Run:

```bash
swift test
swift build -c release
git diff --check v0.3.1..HEAD
git status --short --branch
```

Repeat packaged-app inspection and the active-task launch check after all review fixes.

- [ ] **Step 2: Request independent reviews**

Run a specification-compliance review against the approved design, then a code-quality review, then a final review covering the full `v0.3.1..HEAD` diff. Resolve every Critical or Important issue and re-run the applicable review.

- [ ] **Step 3: Report evidence**

Report exact test counts, build status, installed application version, active-task process result, crash-log comparison, Homebrew-prefix Codex removal state, DMG SHA-256, branch name, commits, and any remaining non-blocking warnings.
