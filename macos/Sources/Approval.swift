import Foundation
import Security

/// What the notch answers to a permission request. `terminal` means "no decision":
/// the hook prints nothing and Claude Code asks as usual. Nothing ever defaults to `allow`.
enum ApprovalDecision: String { case allow, deny, terminal }

struct ApprovalRequest {
    let tool: String
    let detail: String
}

/// Private local channel between `ClawdBuddy hook` (PermissionRequest) and the running app:
/// a Unix socket in a 0700 folder plus a random token in a 0600 file. The hook sends the token,
/// and only trusts an answer from a peer that runs this very executable and echoes the token back.
enum ApprovalChannel {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClawdBuddy", isDirectory: true)
    static var socketPath: String { dir.appendingPathComponent("approve.sock").path }
    static var tokenPath: String { dir.appendingPathComponent("token").path }

    /// How long the hook waits for the app; the card itself closes after `cardSeconds`.
    static let cardSeconds: TimeInterval = 20
    static let hookWaitSeconds: TimeInterval = 25

    static func executablePath(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path
    }

    static func makeAddress() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        return addr
    }

    static func connect(_ fd: Int32, _ addr: inout sockaddr_un) -> Bool {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    static func setReadTimeout(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Reads one newline-terminated JSON object (capped), or nil on timeout / EOF / garbage.
    static func readMessage(_ fd: Int32) -> [String: String]? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 64 * 1024 {
            let n = read(fd, &byte, 1)
            if n <= 0 { return nil }
            if byte == UInt8(ascii: "\n") { break }
            data.append(byte)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }

    static func writeMessage(_ fd: Int32, _ message: [String: String]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
    }

    static func sameToken(_ a: String?, _ b: String) -> Bool {
        guard let a, a.utf8.count == b.utf8.count, !b.isEmpty else { return false }
        return zip(a.utf8, b.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: Hook side

    /// Blocks until the app answers, at most `hookWaitSeconds`. Any problem means `.terminal`.
    static func ask(_ request: ApprovalRequest) -> ApprovalDecision {
        guard let token = try? String(contentsOfFile: tokenPath, encoding: .utf8), !token.isEmpty,
              var addr = makeAddress() else { return .terminal }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .terminal }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, &addr) else { return .terminal }

        // Only our own app may answer: the peer must be this same executable.
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0,
              let peer = executablePath(of: pid), let me = executablePath(of: getpid()), peer == me
        else { return .terminal }

        writeMessage(fd, ["token": token, "tool": request.tool, "detail": request.detail])
        setReadTimeout(fd, hookWaitSeconds)
        guard let reply = readMessage(fd), sameToken(reply["token"], token),
              let decision = ApprovalDecision(rawValue: reply["decision"] ?? "") else { return .terminal }
        return decision
    }
}

/// One pending request on the app side. Answer once; `onHangup` fires if the hook goes away first
/// (Claude Code got its answer elsewhere, or killed the hook).
final class ApprovalTicket {
    let request: ApprovalRequest
    var onHangup: (() -> Void)?
    private let fd: Int32
    private let token: String
    private var hangupSource: DispatchSourceRead?
    private var done = false

    fileprivate init(request: ApprovalRequest, fd: Int32, token: String) {
        self.request = request
        self.fd = fd
        self.token = token
        // The hook never writes again, so "readable" means it hung up.
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.done else { return }
            self.finish()
            self.onHangup?()
        }
        hangupSource = src
        src.resume()
    }

    var isOpen: Bool { !done }

    func answer(_ decision: ApprovalDecision) {
        guard !done else { return }
        ApprovalChannel.writeMessage(fd, ["token": token, "decision": decision.rawValue])
        finish()
    }

    private func finish() {
        done = true
        hangupSource?.cancel()
        hangupSource = nil
        close(fd)
    }
}

/// Listens on the approval socket. Requests arrive on the main queue.
final class ApprovalServer {
    var onRequest: ((ApprovalTicket) -> Void)?
    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.clawdbuddy.approval")
    private var token = ""

    func start() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ApprovalChannel.dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        chmod(ApprovalChannel.dir.path, 0o700)

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        unlink(ApprovalChannel.tokenPath)
        guard fm.createFile(atPath: ApprovalChannel.tokenPath, contents: Data(token.utf8),
                            attributes: [.posixPermissions: 0o600]) else { return }

        guard var addr = ApprovalChannel.makeAddress() else { return }
        unlink(ApprovalChannel.socketPath)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); fd = -1; return }
        chmod(ApprovalChannel.socketPath, 0o600)

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        acceptSource = src
        src.resume()
    }

    func stop() {
        acceptSource?.cancel()
        if fd >= 0 { close(fd) }
        fd = -1
        unlink(ApprovalChannel.socketPath)
        unlink(ApprovalChannel.tokenPath)
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        // A hook that already gave up must not take the app down with SIGPIPE.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        ApprovalChannel.setReadTimeout(client, 2)
        guard let msg = ApprovalChannel.readMessage(client), ApprovalChannel.sameToken(msg["token"], token) else {
            close(client)
            return
        }
        let request = ApprovalRequest(tool: msg["tool"] ?? "", detail: msg["detail"] ?? "")
        DispatchQueue.main.async { [weak self] in
            let ticket = ApprovalTicket(request: request, fd: client, token: self?.token ?? "")
            if let handler = self?.onRequest { handler(ticket) } else { ticket.answer(.terminal) }
        }
    }
}
