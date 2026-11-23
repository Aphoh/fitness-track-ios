import Foundation
import Observation
import SwiftUI

/// Owns the in-memory AppState and keeps it in sync with the state file.
///
/// The file defaults to `Documents/FitnessTrack.json` (visible in the Files
/// app under "On My iPhone › FitnessTrack"). The user can move it anywhere —
/// typically iCloud Drive — via the document picker; that choice is
/// remembered with a security-scoped bookmark.
@MainActor @Observable
final class StateStore {
    private(set) var state: AppState
    private(set) var fileURL: URL
    private(set) var lastError: String?
    private(set) var lastSaved: Date?

    @ObservationIgnored private var file: StateFile?
    @ObservationIgnored private var scopedURL: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persist: Bool
    /// False while the current file holds data that couldn't be decoded, so it is never overwritten.
    @ObservationIgnored private var writable = true
    @ObservationIgnored var todayProvider: () -> String = { LocalDate.today() }

    static let bookmarkKey = "stateFileBookmark"
    static let defaultFileName = "FitnessTrack.json"
    static var documentsURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var defaultFileURL: URL { documentsURL.appendingPathComponent(defaultFileName) }

    var today: String { todayProvider() }
    var isUsingDefaultLocation: Bool { fileURL.standardizedFileURL == Self.defaultFileURL.standardizedFileURL }
    var isInICloud: Bool { (try? fileURL.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem ?? false }

    /// In-memory store (previews/tests).
    init(preview state: AppState) {
        self.state = state
        self.fileURL = Self.defaultFileURL
        self.defaults = .standard
        self.persist = false
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persist = true
        self.state = AppState()
        self.fileURL = Self.defaultFileURL
        if let url = Self.resolveBookmark(defaults), url.startAccessingSecurityScopedResource() {
            scopedURL = url
            fileURL = url
        }
        open(fileURL, seedIfMissing: true)
    }

    /// A store backed by a specific file (tests).
    init(fileURL: URL, defaults: UserDefaults) {
        self.defaults = defaults
        self.persist = true
        self.state = AppState()
        self.fileURL = fileURL
        open(fileURL, seedIfMissing: true)
    }

    // MARK: Mutation

    /// Apply a mutation and save. Errors from the engine are returned, not thrown, for UI convenience.
    @discardableResult
    func update<T>(_ body: (inout AppState) throws -> T) -> Result<T, Error> {
        // Pick up an external edit whose change notification hasn't arrived yet,
        // so saving this mutation doesn't overwrite it.
        if let file, file.hasExternalChange() { reloadFromDisk() }
        var copy = state
        do {
            let r = try body(&copy)
            if copy != state { try save(copy); state = copy }
            return .success(r)
        } catch {
            return .failure(error)
        }
    }

    func replaceState(_ new: AppState) throws { try save(new); state = new }

    // MARK: File handling

    private func open(_ url: URL, seedIfMissing: Bool) {
        file?.close()
        let f = StateFile(url: url) { [weak self] in
            Task { @MainActor in self?.reloadFromDisk() }
        }
        file = f
        writable = true
        do {
            if let data = try f.read() {
                state = try Self.decode(data)
                lastError = nil
            } else if seedIfMissing {
                saveOrReport(AppState.seeded(today: today))
            }
        } catch {
            writable = false
            lastError = Self.unreadable(url, error)
        }
    }

    func reloadFromDisk() {
        guard let file, let data = try? file.read() else { return }
        do {
            let s = try Self.decode(data)
            writable = true
            lastError = nil
            if s != state { state = s }
        } catch {
            writable = false
            lastError = Self.unreadable(fileURL, error)
        }
    }

    private static func unreadable(_ url: URL, _ error: Error) -> String {
        "Couldn't read \(url.lastPathComponent), so changes aren't saved to it: \(error.localizedDescription)"
    }

    private func save(_ new: AppState) throws {
        guard persist, let file else { return }
        guard writable else { throw EngineError.invalid(lastError ?? Self.unreadable(fileURL, EngineError.invalid("unreadable data"))) }
        do {
            try file.write(try StateFile.encoder.encode(new))
            lastSaved = Date()
            lastError = nil
        } catch {
            lastError = "Couldn't save: \(error.localizedDescription)"
            throw error
        }
    }

    /// Save outside a user mutation (seeding, relocating); failures surface via `lastError`.
    private func saveOrReport(_ new: AppState) {
        state = new
        try? save(new)
    }

    /// Coordinated read of a file the app may not be presenting; nil when it doesn't exist.
    private static func coordinatedRead(_ url: URL) throws -> Data? {
        var coordError: NSError?
        var result: Result<Data?, Error> = .success(nil)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            guard FileManager.default.fileExists(atPath: u.path) else { return }
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    static func decode(_ data: Data) throws -> AppState {
        let dec = JSONDecoder()
        if let s = try? dec.decode(AppState.self, from: data), s.format == AppState.format { return s }
        // Also accept a FitnessTrack web export as a state file.
        if let ft = try? dec.decode(FTExport.self, from: data) {
            var s = AppState.seeded(today: LocalDate.today())
            try s.importFT(ft, today: LocalDate.today())
            return s
        }
        return try dec.decode(AppState.self, from: data)
    }

    /// Use an existing state file (e.g. one already in iCloud Drive) — replaces the in-memory state with its contents.
    func openExistingFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let data = try Self.coordinatedRead(url) else { throw EngineError.notFound("The file doesn't exist") }
            _ = try Self.decode(data)
        } catch {
            lastError = "\(url.lastPathComponent) isn't a FitnessTrack data file, so it wasn't opened: \(error.localizedDescription)"
            return
        }
        adopt(url)
        open(url, seedIfMissing: false)
    }

    /// Move the current data to a new file in a folder the user picked.
    func saveToFolder(_ folder: URL) {
        let ok = folder.startAccessingSecurityScopedResource()
        let target = folder.appendingPathComponent(Self.defaultFileName)
        if ok { adoptFolderTarget(folder: folder, target: target) }
        else { lastError = "No permission to write in \(folder.lastPathComponent)" }
    }

    private func adoptFolderTarget(folder: URL, target: URL) {
        let current = state
        let existing: AppState?
        do {
            existing = try Self.coordinatedRead(target).map(Self.decode)
        } catch {
            if scopedURL != folder { folder.stopAccessingSecurityScopedResource() }
            lastError = "\(folder.lastPathComponent) already has a \(Self.defaultFileName) that couldn't be read, so it was left untouched: \(error.localizedDescription)"
            return
        }
        // Bookmark the folder's file; the folder scope keeps access for the file.
        if let bm = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bm, forKey: Self.bookmarkKey + ".folder")
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = folder
        fileURL = target
        file?.close()
        file = StateFile(url: target) { [weak self] in Task { @MainActor in self?.reloadFromDisk() } }
        defaults.removeObject(forKey: Self.bookmarkKey)
        writable = true
        if let existing {
            _ = try? file?.read()   // registers the presenter's baseline
            state = existing        // a state file already lives there — use it
            lastError = nil
        } else {
            saveOrReport(current)
        }
    }

    private func adopt(_ url: URL) {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = url.startAccessingSecurityScopedResource() ? url : nil
        fileURL = url
        defaults.removeObject(forKey: Self.bookmarkKey + ".folder")
        if let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(bm, forKey: Self.bookmarkKey)
        }
    }

    /// Go back to the app's Documents folder (copies the current data there).
    func useDefaultLocation() {
        let current = state
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
        defaults.removeObject(forKey: Self.bookmarkKey + ".folder")
        fileURL = Self.defaultFileURL
        open(fileURL, seedIfMissing: false)
        writable = true   // the user chose to put the current data here
        saveOrReport(current)
    }

    private static func resolveBookmark(_ defaults: UserDefaults) -> URL? {
        var stale = false
        if let bm = defaults.data(forKey: bookmarkKey),
           let url = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: bookmarkKey) }
            return url
        }
        if let bm = defaults.data(forKey: bookmarkKey + ".folder"),
           let folder = try? URL(resolvingBookmarkData: bm, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            if stale, let fresh = try? folder.bookmarkData() { defaults.set(fresh, forKey: bookmarkKey + ".folder") }
            _ = folder.startAccessingSecurityScopedResource()
            return folder.appendingPathComponent(defaultFileName)
        }
        return nil
    }

    // MARK: Export / restore

    func exportData() throws -> Data {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return try StateFile.encoder.encode(state.exportFT(appVersion: v))
    }

    @discardableResult
    func restore(from url: URL) throws -> AppState.ImportCounts {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try Self.coordinatedRead(url) else { throw EngineError.invalid("Couldn't read the file") }
        let dec = JSONDecoder()
        if let s = try? dec.decode(AppState.self, from: data), s.format == AppState.format {
            try replaceState(s)
            return .init(plans: s.plans.count, sessions: s.sessions.count, sets: s.loggedSets.count, createdExercises: 0)
        }
        let ft: FTExport
        do { ft = try dec.decode(FTExport.self, from: data) } catch { throw EngineError.invalid("Not a FitnessTrack export file") }
        let t = today
        let r = update { try $0.importFT(ft, today: t) }
        return try r.get()
    }
}
