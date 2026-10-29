import CLibSSH2
import Darwin
import Foundation

enum ProbeError: Error, CustomStringConvertible, Sendable {
    case failed(String, Int32)

    var description: String {
        switch self {
        case let .failed(operation, code):
            return "\(operation)失败，错误码：\(code)"
        }
    }
}

/// A bounded readiness bridge for this one-shot CLI. The blocking poll runs on
/// a dedicated OS thread, never MainActor or Swift's cooperative executor.
/// Production should use one cancellable kqueue reactor shared by all sessions.
enum SocketReadiness {
    static func wait(fd: Int32, directions: Int32, timeoutMilliseconds: Int32) async throws -> Bool {
        let events: Int16 =
            (directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 ? Int16(POLLIN) : 0)
            | (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 ? Int16(POLLOUT) : 0)
        guard events != 0 else { throw ProbeError.failed("获取等待方向", directions) }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
                if result < 0 {
                    continuation.resume(throwing: ProbeError.failed("等待 socket 就绪", errno))
                } else if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                    continuation.resume(throwing: ProbeError.failed("socket 状态", Int32(descriptor.revents)))
                } else {
                    continuation.resume(returning: result > 0)
                }
            }
        }
    }
}

/// Owns every libssh2 handle inside one actor. No C pointer escapes its executor.
/// This probe uses a local socket pair; it does not connect or authenticate.
actor LibSSH2Probe {
    private var running = false

    func run() async throws -> [String] {
        guard !running else { throw ProbeError.failed("重复运行探针", -1) }
        running = true
        defer { running = false }

        let initialized = libssh2_init(0)
        guard initialized == 0 else { throw ProbeError.failed("初始化 libssh2", initialized) }
        defer { libssh2_exit() }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw ProbeError.failed("创建 libssh2 session", -1)
        }
        // There are no authenticated channels, so free requires no network I/O.
        defer { libssh2_session_free(session) }
        libssh2_session_set_blocking(session, 0)

        var lines = ["libssh2：\(String(cString: libssh2_version(0)))", "Swift 6 actor + C 模块：通过"]
        for (name, method) in [
            ("KEX", LIBSSH2_METHOD_KEX),
            ("HOSTKEY", LIBSSH2_METHOD_HOSTKEY),
            ("CIPHER", LIBSSH2_METHOD_CRYPT_CS)
        ] {
            var algorithms: UnsafeMutablePointer<UnsafePointer<CChar>?>?
            let count = libssh2_session_supported_algs(session, method, &algorithms)
            guard count > 0, let algorithms else {
                throw ProbeError.failed("读取 \(name) 算法", count)
            }
            let names = (0..<Int(count)).compactMap { index in
                algorithms[index].map { String(cString: $0) }
            }
            libssh2_free(session, algorithms)
            lines.append("\(name)：\(names.joined(separator: ","))")
        }
        for (method, name) in [
            (LIBSSH2_METHOD_CRYPT_CS, "aes128-cbc"),
            (LIBSSH2_METHOD_CRYPT_SC, "aes128-cbc"),
            (LIBSSH2_METHOD_KEX, "diffie-hellman-group14-sha1"),
            (LIBSSH2_METHOD_HOSTKEY, "ssh-rsa"),
            (LIBSSH2_METHOD_SIGN_ALGO, "ssh-rsa")
        ] {
            let result = name.withCString { libssh2_session_method_pref(session, method, $0) }
            guard result == 0 else { throw ProbeError.failed("设置算法 \(name)", result) }
        }
        lines.append("旧算法偏好设置：aes128-cbc / group14-sha1 / ssh-rsa 均被 API 接受（未验证远端协商）")

        var sockets: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw ProbeError.failed("创建本地 socket 对", errno)
        }
        let client = sockets[0]
        let peer = sockets[1]
        defer {
            Darwin.close(client)
            Darwin.close(peer)
        }
        for fd in sockets {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw ProbeError.failed("设置非阻塞 socket", errno)
            }
        }
        let first = libssh2_session_handshake(session, client)
        guard first == LIBSSH2_ERROR_EAGAIN else { throw ProbeError.failed("验证握手 EAGAIN", first) }
        let directions = libssh2_session_block_directions(session)
        // Peer sends nothing: the wait must sleep in the kernel and time out.
        let idleReady = try await SocketReadiness.wait(fd: client, directions: directions, timeoutMilliseconds: 100)
        guard !idleReady else { throw ProbeError.failed("验证空闲等待", -1) }
        lines.append("非阻塞握手：EAGAIN，方向 \(directions)；无数据等待 100 ms 正常超时")

        // This is only an SSH identification line, not an SSH server.
        let banner = Array("SSH-2.0-DockShellM0\r\n".utf8)
        let written = banner.withUnsafeBytes { Darwin.write(peer, $0.baseAddress, $0.count) }
        guard written == banner.count else { throw ProbeError.failed("写入本地测试 banner", errno) }
        let ready = try await SocketReadiness.wait(fd: client, directions: directions, timeoutMilliseconds: 100)
        guard ready else { throw ProbeError.failed("验证就绪唤醒", -1) }
        let second = libssh2_session_handshake(session, client)
        guard second == LIBSSH2_ERROR_EAGAIN else { throw ProbeError.failed("验证继续握手", second) }
        lines.append("本地就绪唤醒并重试：通过；未登录服务器，未访问 agent 或任何私钥")
        return lines
    }
}

@main
enum ProbeMain {
    static func main() async {
        do {
            for line in try await LibSSH2Probe().run() { print(line) }
        } catch {
            print("技术验证失败：\(error)")
            Foundation.exit(1)
        }
    }
}
