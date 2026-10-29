import DockShellDomain
import Foundation

/// File metadata/bookmark IO only; the private key remains in the chosen external file.
public actor PrivateKeyBookmarks: PrivateKeyFileAccess {
    public init() {}

    public func bookmark(for url: URL) throws -> Data {
        try validate(url)
        do { return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw DockShellError.privateKeyUnavailable }
    }

    public func displayName(for bookmark: Data) throws -> String {
        try resolve(for: bookmark).lastPathComponent
    }

    public func resolve(for bookmark: Data) throws -> URL {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw DockShellError.privateKeyUnavailable }
            try validate(url)
            return url
        } catch {
            throw (error as? DockShellError) ?? .privateKeyUnavailable
        }
    }

    private func validate(_ url: URL) throws {
        guard url.isFileURL else { throw DockShellError.privateKeyUnavailable }
        if url.pathExtension.lowercased() == "ppk" { throw DockShellError.unsupportedPrivateKey }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true else { throw DockShellError.privateKeyUnavailable }
        } catch { throw DockShellError.privateKeyUnavailable }
    }
}
