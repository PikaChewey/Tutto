//
//  ArchiveFileSystem.swift
//  TuttoKit — archives
//
//  Small POSIX helpers shared by the extractor and compressor: lstat-based existence, realpath,
//  exclusive renames (never overwrite), robust removal of temporary trees, quarantine copying,
//  and entry-path sanitising.
//

import Darwin
import Foundation

enum FileSystem {
    /// lstat-based: a dangling symlink exists.
    static func itemExists(_ url: URL) -> Bool {
        var st = stat()
        return url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
    }

    static func lstatInfo(_ url: URL) -> stat? {
        var st = stat()
        let ok = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return lstat(path, &st) == 0
        }
        return ok ? st : nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        guard let st = lstatInfo(url) else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Fully resolved path (symlinks such as /var → /private/var removed), needed because
    /// ARCHIVE_EXTRACT_SECURE_SYMLINKS rejects any symlink anywhere in the absolute path.
    static func realPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// Moves `source` to `proposed` or the next free "Name N" sibling, atomically refusing to
    /// replace anything (renamex_np RENAME_EXCL). Returns the URL actually used.
    static func moveExclusively(_ source: URL, toUniqueURLFor proposed: URL, isDirectory: Bool) throws -> URL {
        for _ in 0..<10_000 {
            let candidate = ArchiveNaming.uniqueURL(for: proposed, isDirectory: isDirectory)
            let result = source.withUnsafeFileSystemRepresentation { src in
                candidate.withUnsafeFileSystemRepresentation { dst in
                    renamex_np(src!, dst!, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return candidate }
            let err = errno
            if err == EEXIST { continue }   // lost a race; pick the next name
            if err == ENOTSUP || err == EINVAL {
                // File system without RENAME_EXCL support: best effort check-then-rename.
                if itemExists(candidate) { continue }
                let r = source.withUnsafeFileSystemRepresentation { src in
                    candidate.withUnsafeFileSystemRepresentation { dst in rename(src!, dst!) }
                }
                if r == 0 { return candidate }
                throw ArchiveError.writeFailed(String(cString: strerror(errno)))
            }
            throw ArchiveError.writeFailed("\(candidate.lastPathComponent): \(String(cString: strerror(err)))")
        }
        throw ArchiveError.writeFailed("No free name for \(proposed.lastPathComponent)")
    }

    /// Removes a tree even when the archive made some of its directories read-only.
    static func forceRemove(_ url: URL) {
        guard itemExists(url) else { return }
        let fm = FileManager.default
        if (try? fm.removeItem(at: url)) != nil, !itemExists(url) { return }
        makeOwnerWritable(url)
        try? fm.removeItem(at: url)
    }

    private static func makeOwnerWritable(_ url: URL) {
        guard let st = lstatInfo(url), (st.st_mode & S_IFMT) == S_IFDIR else { return }
        url.withUnsafeFileSystemRepresentation { path in
            if let path { _ = chmod(path, (st.st_mode & 0o7777) | S_IRWXU) }
        }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for child in children {
            makeOwnerWritable(url.appendingPathComponent(child))
        }
    }

    /// Ensures the owner can always read/write what was extracted (folders u+rwx, files u+rw).
    /// Without this, archives from read-only media (ISO: 0555 folders)
    /// produce folders that can't be renamed into place, trashed or cleaned up.
    static func ensureOwnerAccess(below root: URL) {
        func fix(_ path: String) {
            var st = stat()
            guard lstat(path, &st) == 0 else { return }
            let type = st.st_mode & S_IFMT
            let mode = st.st_mode & 0o7777
            if type == S_IFDIR, mode & S_IRWXU != S_IRWXU {
                _ = chmod(path, mode | S_IRWXU)
            } else if type == S_IFREG, mode & (S_IRUSR | S_IWUSR) != (S_IRUSR | S_IWUSR) {
                _ = chmod(path, mode | S_IRUSR | S_IWUSR)
            }
            if type == S_IFDIR {
                for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                    fix(path + "/" + child)
                }
            }
        }
        for child in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
            fix(root.path + "/" + child)
        }
    }

    // MARK: Quarantine

    static let quarantineAttribute = "com.apple.quarantine"

    static func quarantine(of url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, quarantineAttribute, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, quarantineAttribute, $0.baseAddress, size, 0, 0) }
            return read > 0 ? data.prefix(read) : nil
        }
    }

    /// Copies a quarantine value onto `root` and everything below it (without following links).
    static func applyQuarantine(_ value: Data, toTree root: URL) {
        func apply(_ url: URL) {
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return }
                value.withUnsafeBytes { buf in
                    _ = setxattr(path, quarantineAttribute, buf.baseAddress, buf.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        apply(root)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator { apply(url) }
    }
}

enum EntryPath {
    /// Sanitises an archive entry path: strips leading "/", drops empty, "." and ".."
    /// components. Returns nil when nothing usable is left.
    static func sanitize(_ path: String) -> String? {
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." || component == ".." { continue }
            parts.append(component)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "/")
    }

    /// AppleDouble debris that zip "mac-ext" normally folds into metadata.
    static func isMacOSXMetadataFolder(_ sanitized: String) -> Bool {
        sanitized == "__MACOSX" || sanitized.hasPrefix("__MACOSX/")
    }
}
