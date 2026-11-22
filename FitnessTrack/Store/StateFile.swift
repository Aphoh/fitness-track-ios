import Foundation

/// Coordinated, atomic reads/writes of the single JSON state file, plus an
/// NSFilePresenter that reports external changes (iCloud Drive sync, another
/// device, the Files app). Works with any location the user picks.
final class StateFile: NSObject, NSFilePresenter, @unchecked Sendable {
    let url: URL
    let presentedItemOperationQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; return q
    }()
    var presentedItemURL: URL? { url }

    private let onExternalChange: @Sendable () -> Void
    private let lock = NSLock()
    private var lastWritten: Data?

    init(url: URL, onExternalChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onExternalChange = onExternalChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }

    func close() { NSFileCoordinator.removeFilePresenter(self) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// nil when the file doesn't exist yet.
    func read() throws -> Data? {
        var coordError: NSError?
        var result: Result<Data?, Error> = .success(nil)
        NSFileCoordinator(filePresenter: self).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            do {
                if !FileManager.default.fileExists(atPath: u.path) {
                    // An iCloud placeholder that hasn't downloaded yet.
                    if (try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus != nil {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: u)
                    }
                    result = .success(nil); return
                }
                result = .success(try Data(contentsOf: u))
            } catch { result = .failure(error) }
        }
        if let coordError { throw coordError }
        let data = try result.get()
        lock.withLock { lastWritten = data }
        return data
    }

    func write(_ data: Data) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: self).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do {
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: u, options: .atomic)
            } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
        lock.withLock { lastWritten = data }
    }

    func presentedItemDidChange() {
        // Ignore our own writes echoed back.
        let current = try? Data(contentsOf: url)
        let ours = lock.withLock { current == lastWritten }
        if !ours { onExternalChange() }
    }
}
