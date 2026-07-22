import Foundation
import XCTest
@testable import CodexMonitor

final class CatFrameResourceLocatorTests: XCTestCase {
    func testResolvesFrameFromInstalledAppResourceBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainResourceURL = root.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let expectedURL = mainResourceURL.appending(
            path: "CodexMonitor_CodexMonitor.bundle/CatFrames/cat-frame-2.png"
        )
        try createEmptyFile(at: expectedURL)

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: mainResourceURL,
            mainBundleURL: root,
            fileManager: .default
        )

        XCTAssertEqual(result, expectedURL)
    }

    func testResolvesFrameFromNativeMacOSResourceBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainResourceURL = root.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let resourceBundleURL = mainResourceURL.appending(
            path: "CodexMonitor_CodexMonitor.bundle",
            directoryHint: .isDirectory
        )
        try createBundleInfoPlist(
            at: resourceBundleURL.appending(path: "Contents/Info.plist")
        )
        let expectedURL = resourceBundleURL.appending(
            path: "Contents/Resources/CatFrames/cat-frame-2.png"
        )
        try createEmptyFile(at: expectedURL)

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: mainResourceURL,
            mainBundleURL: root,
            fileManager: .default
        )

        XCTAssertEqual(result, expectedURL)
    }

    func testResolvesFrameFromSwiftPMExecutableLayout() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainBundleURL = root.appending(path: ".build/debug", directoryHint: .isDirectory)
        let expectedURL = mainBundleURL.appending(
            path: "CodexMonitor_CodexMonitor.bundle/CatFrames/cat-frame-2.png"
        )
        try createEmptyFile(at: expectedURL)

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: root.appending(path: "unrelated", directoryHint: .isDirectory),
            mainBundleURL: mainBundleURL,
            fileManager: .default
        )

        XCTAssertEqual(result, expectedURL)
    }

    func testResolvesFrameFromDirectMainResourceLayout() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainResourceURL = root.appending(path: "Resources", directoryHint: .isDirectory)
        let expectedURL = mainResourceURL.appending(path: "CatFrames/cat-frame-2.png")
        try createEmptyFile(at: expectedURL)

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: mainResourceURL,
            mainBundleURL: root.appending(path: "unrelated", directoryHint: .isDirectory),
            fileManager: .default
        )

        XCTAssertEqual(result, expectedURL)
    }

    func testResolvesCustomFramePrefix() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainResourceURL = root.appending(path: "Resources", directoryHint: .isDirectory)
        let expectedURL = mainResourceURL.appending(path: "CatFrames/thinking-frame-2.png")
        try createEmptyFile(at: expectedURL)

        let result = CatFrameResourceLocator.frameURL(
            prefix: "thinking-frame",
            index: 2,
            mainResourceURL: mainResourceURL,
            mainBundleURL: root.appending(path: "unrelated", directoryHint: .isDirectory),
            fileManager: .default
        )

        XCTAssertEqual(result, expectedURL)
    }

    func testMissingFrameReturnsNil() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: root.appending(path: "Resources", directoryHint: .isDirectory),
            mainBundleURL: root,
            fileManager: .default
        )

        XCTAssertNil(result)
    }

    func testReturnsFirstAvailableFrameInCandidateOrder() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainResourceURL = root.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        let mainBundleURL = root.appending(path: "Executable", directoryHint: .isDirectory)
        let expectedURL = mainResourceURL.appending(
            path: "CodexMonitor_CodexMonitor.bundle/CatFrames/cat-frame-2.png"
        )
        try createEmptyFile(at: expectedURL)
        try createEmptyFile(
            at: mainBundleURL.appending(
                path: "CodexMonitor_CodexMonitor.bundle/CatFrames/cat-frame-2.png"
            )
        )
        try createEmptyFile(
            at: mainResourceURL.appending(path: "CatFrames/cat-frame-2.png")
        )

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: mainResourceURL,
            mainBundleURL: mainBundleURL,
            fileManager: .default
        )

        XCTAssertEqual(result, expectedURL)
    }

    func testReadableDirectoryNamedLikeFrameReturnsNil() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let mainResourceURL = root.appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: mainResourceURL.appending(
                path: "CatFrames/cat-frame-2.png",
                directoryHint: .isDirectory
            ),
            withIntermediateDirectories: true
        )

        let result = CatFrameResourceLocator.frameURL(
            index: 2,
            mainResourceURL: mainResourceURL,
            mainBundleURL: root.appending(path: "unrelated", directoryHint: .isDirectory),
            fileManager: .default
        )

        XCTAssertNil(result)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createEmptyFile(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
    }

    private func createBundleInfoPlist(at url: URL) throws {
        let propertyList: [String: Any] = [
            "CFBundleIdentifier": "com.example.CodexMonitorTests.\(UUID().uuidString)",
            "CFBundlePackageType": "BNDL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }
}
