import Foundation

enum CatFrameResourceLocator {
    static func frameURL(
        prefix: String = "cat-frame",
        index: Int,
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> URL? {
        let frameName = "\(prefix)-\(index)"
        let resourceBundleRoots = [
            mainResourceURL?.appending(
                path: "CodexMonitor_CodexMonitor.bundle",
                directoryHint: .isDirectory
            ),
            mainBundleURL.appending(
                path: "CodexMonitor_CodexMonitor.bundle",
                directoryHint: .isDirectory
            ),
        ]

        for resourceBundleRoot in resourceBundleRoots.compactMap({ $0 }) {
            if let url = Bundle(url: resourceBundleRoot)?.url(
                forResource: frameName,
                withExtension: "png",
                subdirectory: "CatFrames"
            ), isReadableRegularFile(at: url, fileManager: fileManager) {
                return url
            }
        }

        guard let url = mainResourceURL?.appending(
            path: "CatFrames/\(frameName).png"
        ), isReadableRegularFile(at: url, fileManager: fileManager) else {
            return nil
        }
        return url
    }

    private static func isReadableRegularFile(
        at url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.isReadableFile(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }
}
