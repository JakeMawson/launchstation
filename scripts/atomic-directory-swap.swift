import Darwin
import Foundation

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data("atomic-directory-swap: \(message)\n".utf8))
    exit(code)
}

func identity(_ url: URL) -> stat {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        let code = errno
        fail("could not inspect \(url.path): \(String(cString: strerror(code)))")
    }
    return value
}

func directoryIdentity(_ url: URL) -> (dev: dev_t, inode: ino_t) {
    let value = identity(url)
    guard (value.st_mode & S_IFMT) == S_IFDIR else {
        fail("refusing a symlink or non-directory path: \(url.path)")
    }
    return (value.st_dev, value.st_ino)
}

func regularFileIdentity(_ url: URL) -> (dev: dev_t, inode: ino_t) {
    let value = identity(url)
    guard (value.st_mode & S_IFMT) == S_IFREG else {
        fail("refusing a symlink or non-regular-file path: \(url.path)")
    }
    return (value.st_dev, value.st_ino)
}

func validatePathComponents(_ url: URL) {
    guard url.path.hasPrefix("/") else {
        fail("path must be absolute: \(url.path)")
    }
    var current = URL(fileURLWithPath: "/", isDirectory: true)
    for component in url.pathComponents.dropFirst() {
        current.appendPathComponent(component)
        let value = identity(current)
        guard (value.st_mode & S_IFMT) == S_IFDIR else {
            fail("refusing a symlink or non-directory path component: \(current.path)")
        }
    }
}

func validateTree(_ directory: URL) {
    validatePathComponents(directory)

    func visit(_ url: URL) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch {
            fail("could not enumerate \(url.path): \(error.localizedDescription)")
        }
        for name in names {
            let child = url.appendingPathComponent(name, isDirectory: false)
            let value = identity(child)
            switch value.st_mode & S_IFMT {
            case S_IFDIR:
                visit(child)
            case S_IFREG:
                continue
            case S_IFLNK:
                fail("refusing symbolic link inside directory tree: \(child.path)")
            default:
                fail("refusing special filesystem entry inside directory tree: \(child.path)")
            }
        }
    }

    visit(directory)
}

func requireAbsent(_ url: URL) {
    var value = stat()
    if lstat(url.path, &value) == 0 {
        fail("destination already exists: \(url.path)")
    }
    let code = errno
    guard code == ENOENT else {
        fail("could not inspect destination \(url.path): \(String(cString: strerror(code)))")
    }
}

func directoryURL(_ rawPath: String) -> URL {
    guard rawPath.hasPrefix("/") else {
        fail("path must be absolute: \(rawPath)")
    }
    let ambiguous = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        .contains { $0 == "." || $0 == ".." }
    guard !ambiguous else {
        fail("refusing a path containing . or .. components: \(rawPath)")
    }
    return URL(fileURLWithPath: rawPath, isDirectory: true)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, arguments[0] == "validate" {
    validateTree(directoryURL(arguments[1]))
    exit(0)
}

guard arguments.count == 3 else {
    fail("usage: atomic-directory-swap validate DIRECTORY | swap SOURCE_DIRECTORY DESTINATION_DIRECTORY | install SOURCE_DIRECTORY ABSENT_DESTINATION_DIRECTORY | swap-file SOURCE_FILE DESTINATION_FILE")
}

let source = directoryURL(arguments[1])
let destination = directoryURL(arguments[2])

switch arguments[0] {
case "swap":
    validatePathComponents(source)
    validatePathComponents(destination)
    let sourceIdentity = directoryIdentity(source)
    let destinationIdentity = directoryIdentity(destination)
    guard sourceIdentity.dev == destinationIdentity.dev else {
        fail("source and destination must be on the same filesystem")
    }
    guard sourceIdentity.inode != destinationIdentity.inode else {
        fail("source and destination identify the same directory")
    }

    let flags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
    guard renamex_np(source.path, destination.path, flags) == 0 else {
        let code = errno
        fail("atomic swap failed: \(String(cString: strerror(code)))", code: 1)
    }

case "install":
    validateTree(source)
    let destinationParent = destination.deletingLastPathComponent()
    validatePathComponents(destinationParent)
    requireAbsent(destination)
    let sourceIdentity = directoryIdentity(source)
    let parentIdentity = directoryIdentity(destinationParent)
    guard sourceIdentity.dev == parentIdentity.dev else {
        fail("source and destination parent must be on the same filesystem")
    }

    let flags = UInt32(RENAME_EXCL | RENAME_NOFOLLOW_ANY)
    guard renamex_np(source.path, destination.path, flags) == 0 else {
        let code = errno
        fail("atomic install failed: \(String(cString: strerror(code)))", code: 1)
    }

case "swap-file":
    validatePathComponents(source.deletingLastPathComponent())
    validatePathComponents(destination.deletingLastPathComponent())
    let sourceIdentity = regularFileIdentity(source)
    let destinationIdentity = regularFileIdentity(destination)
    guard sourceIdentity.dev == destinationIdentity.dev else {
        fail("source and destination must be on the same filesystem")
    }
    guard sourceIdentity.inode != destinationIdentity.inode else {
        fail("source and destination identify the same regular file")
    }

    let flags = UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
    guard renamex_np(source.path, destination.path, flags) == 0 else {
        let code = errno
        fail("atomic regular-file swap failed: \(String(cString: strerror(code)))", code: 1)
    }

default:
    fail("usage: atomic-directory-swap validate DIRECTORY | swap SOURCE_DIRECTORY DESTINATION_DIRECTORY | install SOURCE_DIRECTORY ABSENT_DESTINATION_DIRECTORY | swap-file SOURCE_FILE DESTINATION_FILE")
}
