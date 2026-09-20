import Foundation
import Darwin

struct CutItem {
    let url: URL
    private let device: dev_t
    private let inode: ino_t

    init?(url: URL) {
        guard let info = Self.info(url) else { return nil }
        self.url = url
        device = info.st_dev
        inode = info.st_ino
    }

    var isOriginal: Bool {
        guard let info = Self.info(url) else { return false }
        return info.st_dev == device && info.st_ino == inode
    }

    private static func info(_ url: URL) -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return lstat(path, &info)
        }
        return result == 0 ? info : nil
    }
}

struct MoveResult {
    let remaining: [CutItem]
    let message: String?
}

enum FinderMover {
    private static let queue = DispatchQueue(label: "de.patrickboesch.cmd-x.finder", qos: .userInitiated)

    static func move(_ items: [CutItem], completion: @escaping (MoveResult) -> Void) {
        queue.async {
            let result = performMove(items)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func performMove(_ items: [CutItem]) -> MoveResult {
        // Validate identity immediately before handing the request to Finder. Never
        // silently move a new file that replaced the original at the same path.
        guard items.allSatisfy(\.isOriginal) else {
            return MoveResult(remaining: items, message: "Die Auswahl wurde inzwischen verändert oder ist nicht erreichbar. Bitte im Finder erneut ausschneiden.")
        }

        let paths = items.map { quote($0.url.path) }.joined(separator: ", ")
        let source = """
        set sourcePaths to {\(paths)}
        set outcomes to ""
        with timeout of 86400 seconds
            tell application "Finder"
                if not frontmost then error "Bitte den Zielordner im Finder öffnen und erneut einfügen." number -128
                set destinationFolder to (insertion location as alias)
                -- Virtual locations (Recents, search results, etc.) must resolve to a real folder.
                set destinationPath to POSIX path of (destinationFolder as alias)
                repeat with itemIndex from 1 to count of sourcePaths
                    try
                        set sourceItem to item ((POSIX file (item itemIndex of sourcePaths)) as text)
                        if (container of sourceItem as alias) is (destinationFolder as alias) then
                            error "Quelle und Ziel sind identisch." number -1303
                        end if
                        -- No replacing: existing destination items are never overwritten.
                        move sourceItem to destinationFolder without replacing
                        set outcomes to outcomes & "OK " & itemIndex & linefeed
                    on error errorText number errorNumber
                        set outcomes to outcomes & "FAIL " & itemIndex & " " & errorNumber & linefeed
                    end try
                end repeat
            end tell
        end timeout
        return outcomes
        """

        // osascript runs separately so Apple Events and large moves never block the
        // menu bar or the event tap. It inherits the app's Automation responsibility.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-s", "h", "-"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return MoveResult(remaining: items, message: "Finder-Steuerung konnte nicht gestartet werden: \(error.localizedDescription)")
        }
        // Drain both output pipes while writing the script: large selections must
        // not fill a pipe and deadlock the helper process.
        let stdout = DataCollector(), stderr = DataCollector()
        let readers = DispatchGroup()
        for (handle, collector) in [(output.fileHandleForReading, stdout), (errors.fileHandleForReading, stderr)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                collector.set(handle.readDataToEndOfFile())
                readers.leave()
            }
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            // Do not kill a Finder transfer: a failed script pipe is reported below.
        }
        process.waitUntilExit()
        readers.wait()
        let text = String(data: stdout.get(), encoding: .utf8) ?? ""
        let errorText = String(data: stderr.get(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let message = errorText.contains("-1743")
                ? "Bitte unter Systemeinstellungen → Datenschutz & Sicherheit → Automation die Finder-Steuerung für CMD-X erlauben."
                : "Finder hat den Vorgang nicht bestätigt. Bitte Quelle und Ziel prüfen und gegebenenfalls neu ausschneiden.\n\(errorText.trimmingCharacters(in: .whitespacesAndNewlines))"
            return MoveResult(remaining: items, message: message)
        }
        let successful = Set(text.split(separator: "\n").compactMap { line -> Int? in
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0] == "OK" else { return nil }
            return Int(fields[1])
        })
        let remaining = items.enumerated().filter { !successful.contains($0.offset + 1) }.map(\.element)
        let message: String? = remaining.isEmpty ? nil : "\(remaining.count) Element(e) wurden nicht verschoben. Prüfe gleiche Dateinamen, Zugriffsrechte und den Zielordner. Die offenen Elemente bleiben vorgemerkt.\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))"
        return MoveResult(remaining: remaining, message: message)
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

private final class DataCollector {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
