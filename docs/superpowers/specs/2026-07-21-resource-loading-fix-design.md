# Codex Monitor Resource Loading Fix Design

## Problem

Codex Monitor v0.3.1 crashes whenever an active Codex task makes the menu bar
switch from the sparkle icon to the running-cat animation. The crash reports
show a Swift assertion in `Bundle.module` while `RunningCatAnimationView` loads
its frames.

The packaged application stores the SwiftPM resource bundle at the conventional
application path:

```text
Codex Monitor.app/Contents/Resources/CodexMonitor_CodexMonitor.bundle
```

However, the release binary's generated SwiftPM accessor searches the app-bundle
root and an absolute `.build` path from the development Mac. The development
path masks the packaging mismatch on the build machine but does not exist on a
clean Mac.

## Scope

The change will:

- replace `Bundle.module` use in the running-cat loader with an explicit,
  non-crashing resource locator;
- support both an installed macOS app and `swift run`/SwiftPM build layouts;
- add automated tests that reproduce the installed-app resource layout;
- make DMG packaging fail if any of the five animation frames is absent;
- build a replacement DMG and install the fixed app on this Mac after preserving
  a recoverable backup of the existing application;
- verify that the weekly quota remains readable and that an active-task resource
  load no longer terminates the process.

The change will not alter quota parsing. The current account returns a valid
weekly window but no five-hour window, and the application already handles that
response by displaying the weekly percentage.

## Selected Design

Introduce a small `CatFrameResourceLocator` responsible only for resolving frame
URLs. It will inspect these layouts in order:

1. `Bundle.main.resourceURL/CodexMonitor_CodexMonitor.bundle/CatFrames`
2. `Bundle.main.bundleURL/CodexMonitor_CodexMonitor.bundle/CatFrames`
3. `Bundle.main.resourceURL/CatFrames`

The first path covers a packaged `.app`, the second covers SwiftPM command-line
build products, and the third provides a direct-resource fallback. Resolution
returns `nil` when a frame is missing; `RunningCatAnimationView.loadFrames()`
will continue using `compactMap`, so a missing optional frame cannot crash the
application.

`RunningCatIcon` will load `NSImage` instances from the resolved file URLs. It
will not reference `Bundle.module`, removing the generated accessor's fatal
failure path from runtime behavior.

## Testing

A new Swift test target will create temporary directory structures for the
installed-app and SwiftPM layouts, place a test frame at the expected location,
and assert that the locator returns the correct file URL. It will also verify
that a missing frame returns `nil` instead of trapping.

TDD order:

1. add the locator tests and confirm they fail because the locator does not yet
   exist;
2. implement the minimal locator and update the animation loader;
3. run the focused tests and the complete Swift test suite;
4. build in release mode;
5. package the DMG and inspect its resource layout, code signature, architecture,
   and absence of a runtime dependency on the development `.build` path;
6. install and launch the fixed app while a Codex task is active, then verify no
   new crash report is generated.

## Packaging and Rollback

The packaging script will validate all five files under
`Contents/Resources/CodexMonitor_CodexMonitor.bundle/CatFrames` before signing.
The generated DMG will remain Apple Silicon-only and ad-hoc signed, matching the
current release process.

Before replacing `/Applications/Codex Monitor.app`, the existing v0.3.1 app will
be copied to a timestamped backup under the task's intermediate `work/`
directory. If launch verification fails, the replacement can be removed and the
backup restored without losing application preferences or Codex data.

## Success Criteria

- all new resource-locator tests pass after demonstrating the expected red
  failure;
- `swift test` and `swift build -c release` exit successfully;
- the packaged app contains all five running-cat PNG files;
- loading the running-cat view no longer accesses the failing generated
  `Bundle.module` path;
- the fixed installed app remains running when Codex is thinking or executing;
- the Homebrew-prefix/npm Codex CLI remains removed while the ChatGPT-embedded
  Codex remains available.
