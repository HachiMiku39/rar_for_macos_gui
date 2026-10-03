import Foundation
import Darwin

public enum ArchiveTaskState: String { case queued, running, completed, failed, cancelled }
public struct ArchiveTaskSnapshot {
    public let id: UUID
    public var state: ArchiveTaskState = .queued
    public var operation: String
    public var bytesRead: UInt64 = 0
    public var bytesWritten: UInt64 = 0
    public var currentFile = ""
    public var error: String?
}

public enum MemoryMode: String, CaseIterable { case adaptive, conservative, performance }
public struct RuntimeBudget {
    public let memory: UInt64
    public let workers: Int
    public let entryLimit: Int
    public static func calculate(ram: UInt64, cores: Int, mode: MemoryMode, pressure: Int = 0) -> RuntimeBudget {
        let gib: UInt64 = 1024 * 1024 * 1024
        // Ceilings, not allocations. Leave at least half the RAM to the system.
        let base = ram <= 8 * gib ? ram / 8 : min(32 * gib, ram / 2)
        let bytes = max(256 * 1024 * 1024, mode == .conservative ? base / 2 : base)
        let workers = pressure > 0 || mode == .conservative ? 1 : max(1, min(cores, mode == .performance ? 16 : 4))
        return RuntimeBudget(memory: bytes, workers: workers, entryLimit: min(1_000_000, Int(bytes / 2048)))
    }
}

/// Process-wide pressure signal. Decoder working sets are never forcibly resized.
public final class ArchiveResources: @unchecked Sendable {
    public static let shared = ArchiveResources()
    private let lock = NSLock()
    private var pressure = 0
    private var mode: MemoryMode = .adaptive
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
    private init() {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.pressure = self.source.data.contains(.critical) ? 2 : self.source.data.contains(.warning) ? 1 : 0 }
        }
        source.resume()
    }
    public func configure(_ mode: MemoryMode) { lock.withLock { self.mode = mode } }
    public var budget: RuntimeBudget { lock.withLock { .calculate(ram: ProcessInfo.processInfo.physicalMemory, cores: ProcessInfo.processInfo.activeProcessorCount, mode: mode, pressure: pressure) } }
    public var critical: Bool { lock.withLock { pressure == 2 } }
}

/// Incremental UTF-8 line/record decoding: listing text is never accumulated twice.
final class ListingDecoder {
    var entries: [ArchiveEntry] = []
    var safetyFlags = Set<String>()
    private var pending = Data()
    private var record = ""
    private let backend: Backend
    private let limit: Int
    init(backend: Backend, limit: Int) { self.backend = backend; self.limit = limit }
    func feed(_ data: Data) throws {
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<end], as: UTF8.self).trimmingCharacters(in: .newlines)
            pending.removeSubrange(...end)
            if line == "Encrypted = +" || line == "Locked = +" || line == "Multivolume = +" || line.hasPrefix("Volumes = ") || line.contains("7zAES") || line.contains("AES-") {
                // Editing decisions must not depend on the bounded display log.
                if safetyFlags.count < 128 { safetyFlags.insert(line) }
            }
            if line.isEmpty { try flush() } else { record += line + "\n" }
            guard record.utf8.count <= 1_048_576 else { throw ArchiveError.invalid("Archive listing record is too large.") }
        }
        guard pending.count <= 1_048_576 else { throw ArchiveError.invalid("Archive listing line is too large.") }
    }
    private func flush() throws {
        let parsed = ArchiveCommands.parse(record, backend: backend)
        guard entries.count <= limit - parsed.count else { throw ArchiveError.invalid("Archive entry index exceeds the current memory budget.") }
        entries += parsed; record = ""
    }
    func finish() throws { if !pending.isEmpty { record += String(decoding: pending, as: UTF8.self); pending = Data() }; try flush() }
}

/// POSIX launch boundary: no NSTask/Objective-C exception can abort the GUI here.
/// One run per runner; stdout/stderr are drained with fixed 64 KiB buffers.
public final class CLIRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var pid: pid_t = 0
    private var cancelled = false
    private var cancelAt: Date?
    private var observer: ((ArchiveTaskSnapshot) -> Void)?
    public var observe: ((ArchiveTaskSnapshot) -> Void)? {
        get { lock.withLock { observer } }
        set { lock.withLock { observer = newValue } }
    }
    public init() {}
    public func cancel() {
        lock.withLock {
            guard active else { return }
            cancelled = true
            if cancelAt == nil { cancelAt = Date() }
            if pid > 0 { kill(-pid, SIGTERM) }
        }
    }
    public func run(executable: String, arguments: [String], directory: URL? = nil, password: String = "", outputFile: URL? = nil, outputLimit: Int? = nil, diskGuard: URL? = nil, update: @escaping (String, String) -> Void) async throws -> CLIResult {
        try Task.checkCancellation()
        _ = try ArchiveCommands.passwordSwitch(password)
        guard executable.hasPrefix("/"), !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }),
              FileManager.default.isExecutableFile(atPath: executable),
              (try? URL(fileURLWithPath: executable).resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ArchiveError.details("Extraction tool failed to launch: {0}", ["Invalid executable or arguments: " + executable])
        }
        if let directory {
            guard directory.isFileURL, !directory.path.contains("\0"), (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw ArchiveError.details("Extraction tool failed to launch: {0}", ["Working directory does not exist."])
            }
        }
        let reserved = lock.withLock { () -> Bool in
            guard !active else { return false }
            active = true; cancelled = false; cancelAt = nil; return true
        }
        guard reserved else { throw ArchiveError.invalid("An engine task is already running.") }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var state = ArchiveTaskSnapshot(id: UUID(), operation: arguments.first ?? "Engine")
                    self.observe?(state)
                    do {
                        let result = try self.execute(executable, arguments, directory, password, outputFile, outputLimit, diskGuard, &state, update)
                        state.state = result.cancelled ? .cancelled : result.status == 0 ? .completed : .failed
                        if result.status != 0 { state.error = result.stderr }
                        self.lock.withLock { self.active = false }
                        self.observe?(state); continuation.resume(returning: result)
                    } catch {
                        state.state = error is CancellationError ? .cancelled : .failed; state.error = error.localizedDescription
                        self.lock.withLock { self.active = false }
                        self.observe?(state); continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { self.cancel() })
    }
    private func execute(_ executable: String, _ arguments: [String], _ directory: URL?, _ password: String, _ outputFile: URL?, _ outputLimit: Int?, _ diskGuard: URL?, _ state: inout ArchiveTaskSnapshot, _ update: (String, String) -> Void) throws -> CLIResult {
        let budget = ArchiveResources.shared.budget
        var fds: [Int32] = []
        func makePipe() throws -> (Int32, Int32) {
            var p: [Int32] = [0, 0]
            guard pipe(&p) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            for fd in p { _ = fcntl(fd, F_SETFD, FD_CLOEXEC); fds.append(fd) }
            return (p[0], p[1])
        }
        func closeFD(_ fd: Int32) { if let index = fds.firstIndex(of: fd) { close(fd); fds.remove(at: index) } }
        defer { for fd in fds { close(fd) } }
        let out = try makePipe(), err = try makePipe(), input = try makePipe()
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ArchiveError.invalid("Cannot initialize engine launch.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ArchiveError.invalid("Cannot initialize engine launch.") }
        defer { posix_spawnattr_destroy(&attributes) }
        func checked(_ code: Int32) throws { if code != 0 { throw ArchiveError.details("Extraction tool failed to launch: {0}", [String(cString: strerror(code))]) } }
        try checked(posix_spawn_file_actions_adddup2(&actions, input.0, STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, out.1, STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, err.1, STDERR_FILENO))
        for fd in fds { try checked(posix_spawn_file_actions_addclose(&actions, fd)) }
        if let directory { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, signal) }
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        var args = ([executable] + arguments).map { strdup($0) } + [nil]
        var env = ["PATH=/usr/bin:/bin", "LANG=en_US.UTF-8", "LC_ALL=en_US.UTF-8", "HOME=" + NSHomeDirectory()].map { strdup($0) } + [nil]
        defer { for p in args { free(p) }; for p in env { free(p) } }
        var child: pid_t = 0
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try checked(posix_spawn(&child, executable, &actions, &attributes, &args, &env))
            pid = child
        }
        state.state = .running; observe?(state)
        closeFD(out.1); closeFD(err.1); closeFD(input.0)
        _ = fcntl(input.1, F_SETNOSIGPIPE, 1)
        if !password.isEmpty {
            // Bounded secret, pipe only; never argv, environment or a disk file.
            let bytes = Array((password + "\n" + password + "\n").utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(input.1, $0.baseAddress, $0.count) }
        }
        closeFD(input.1)
        for fd in [out.0, err.0] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
        var binaryFD: Int32 = -1, partial: URL?, committed = false
        var failure: String?
        if let outputFile {
            let file = outputFile.deletingLastPathComponent().appendingPathComponent(".ArchiveDesk-" + UUID().uuidString + ".partial")
            partial = file
            binaryFD = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if binaryFD < 0 { failure = "Cannot create temporary output: " + String(cString: strerror(errno)); cancel() }
        }
        defer { if binaryFD >= 0 { close(binaryFD) }; if !committed, let partial { try? FileManager.default.removeItem(at: partial) } }
        let listing = arguments.first == "l" || arguments.first == "lt"
            ? ListingDecoder(backend: arguments.first == "lt" ? .rar : .sevenZip, limit: budget.entryLimit) : nil
        var stdout = Data(), stderr = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var eofOut = false, eofErr = false, reaped = false, waitStatus: Int32 = 0
        var lastUpdate = Date.distantPast, lastMonitor = Date.distantPast, exitedAt: Date?
        func text(_ bytes: Data) -> String {
            let s = String(decoding: bytes, as: UTF8.self)
            return password.isEmpty ? s : s.replacingOccurrences(of: password, with: "••••")
        }
        // Reap under the cancellation lock: never signal a recycled PID.
        while !reaped || !eofOut || !eofErr {
            let now = Date()
            if !reaped {
                lock.withLock {
                    if let cancelAt, now.timeIntervalSince(cancelAt) > 2, pid > 0 { kill(-pid, SIGKILL) }
                    let r = waitpid(child, &waitStatus, WNOHANG)
                    if r == child || (r < 0 && errno == ECHILD) { pid = 0; reaped = true; exitedAt = now }
                }
            }
            if now.timeIntervalSince(lastMonitor) > 0.5 && !reaped {
                lastMonitor = now
                var usage = rusage_info_v2()
                let memory = withUnsafeMutablePointer(to: &usage) { p in
                    p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(child, RUSAGE_INFO_V2, $0) }
                }
                if memory == 0 && usage.ri_resident_size > budget.memory { failure = "Engine exceeded the memory budget. The task stopped safely."; cancel() }
                if ArchiveResources.shared.critical { failure = "System memory pressure is critical. The task stopped safely."; cancel() }
                if let location = diskGuard ?? outputFile?.deletingLastPathComponent(), !DiskSpace.hasReserve(at: location) { failure = "Not enough disk space. The task stopped safely."; cancel() }
            }
            for (fd, isError) in [(out.0, false), (err.0, true)] {
                if isError ? eofErr : eofOut { continue }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count == 0 { if isError { eofErr = true } else { eofOut = true }; continue }
                if count < 0 {
                    if errno != EAGAIN && errno != EINTR { failure = "Unable to read engine output."; cancel(); if isError { eofErr = true } else { eofOut = true } }
                    continue
                }
                state.bytesRead += UInt64(count)
                let data = Data(buffer.prefix(count))
                if !isError && outputFile != nil {
                    if failure == nil {
                        if let outputLimit, state.bytesWritten > UInt64(max(0, outputLimit)) || UInt64(count) > UInt64(max(0, outputLimit)) - state.bytesWritten {
                            failure = "Binary output limit exceeded or write failed."; cancel()
                        } else {
                            var offset = 0
                            while offset < count {
                                let n = data.withUnsafeBytes { Darwin.write(binaryFD, $0.baseAddress!.advanced(by: offset), count - offset) }
                                if n < 0 && errno == EINTR { continue }
                                if n <= 0 { failure = "Binary output limit exceeded or write failed."; cancel(); break }
                                offset += n; state.bytesWritten += UInt64(n)
                            }
                        }
                    }
                } else {
                    if !isError, let listing, failure == nil { do { try listing.feed(data) } catch { failure = error.localizedDescription; cancel() } }
                    // Keep the initial archive properties and a bounded diagnostic tail.
                    if isError { stderr.append(data); if stderr.count > 262_144 { stderr.removeFirst(stderr.count - 262_144) } }
                    else if listing != nil { if stdout.count < 524_288 { stdout.append(data.prefix(524_288 - stdout.count)) } }
                    else { stdout.append(data); if stdout.count > 524_288 { stdout.removeFirst(stdout.count - 524_288) } }
                }
            }
            if now.timeIntervalSince(lastUpdate) >= 0.2 {
                lastUpdate = now
                if password.isEmpty { update(text(stdout), text(stderr)) }
                observe?(state)
            }
            // A helper that leaves descendants holding pipes cannot hang the app forever.
            if let exitedAt, now.timeIntervalSince(exitedAt) > 2 && (!eofOut || !eofErr) { failure = "Engine output pipes did not close."; break }
            if !reaped || !eofOut || !eofErr {
                var p = [pollfd(fd: out.0, events: Int16(POLLIN), revents: 0), pollfd(fd: err.0, events: Int16(POLLIN), revents: 0)]
                _ = poll(&p, 2, 20)
            }
        }
        if failure == nil { do { try listing?.finish() } catch { failure = error.localizedDescription } }
        let wasCancelled = lock.withLock { cancelled }
        let status: Int32 = (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
        if status == 0 && !wasCancelled && failure == nil, let partial, let outputFile {
            if fsync(binaryFD) != 0 { failure = "Unable to flush temporary output." }
            else if Darwin.link(partial.path, outputFile.path) != 0 { failure = "Cannot publish output; destination exists or is unavailable." }
            else { try? FileManager.default.removeItem(at: partial); committed = true }
        }
        let a = text(stdout) + (listing.map { text(Data(("\n" + $0.safetyFlags.sorted().joined(separator: "\n")).utf8)) } ?? ""), b = text(stderr) + (failure.map { "\n" + $0 } ?? "")
        update(a, b)
        return CLIResult(status: failure == nil ? status : 2, stdout: a, stderr: b, cancelled: wasCancelled && failure == nil, listingOutput: "", parsedEntries: listing?.entries)
    }
}

public enum DiskSpace {
    public static let reserve: UInt64 = 64 * 1024 * 1024
    public static func available(at url: URL) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: url.path), let n = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return n.uint64Value
    }
    public static func hasReserve(at url: URL) -> Bool { available(at: url).map { $0 >= reserve } ?? false }
    public static func require(_ bytes: UInt64, at url: URL) throws {
        guard let free = available(at: url), free >= reserve, bytes <= free - reserve else { throw ArchiveError.invalid("Not enough disk space. The task stopped safely.") }
    }
}
