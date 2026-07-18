import Foundation

/// Chrome Native Messaging host —— 由 bundle 内 wrapper `usagebar-native-host` 以 `--native-host`
/// 拉起(见 `main.swift`)。协议:stdin 先 4-byte 长度(平台字节序,macOS = little-endian)+ JSON body;
/// 回一条同格式的 ack。本 host **只做**:校验消息是合法 JSON 对象 → 原子写交接文件 → ack → 退出。
/// 不解析业务、不发网络、不起 AppKit。
///
/// SC7:解析失败绝不记录原始 stdin 字节(只可记错误类别)。
enum ClaudeWebNativeHost {
    /// Chrome 单条 native message 上限 ~1MB;拒绝异常长度,防内存滥用。
    /// 显式 UInt32 —— 与 `decodeLength` 返回的 UInt32 同类型,避免异构比较。
    static let maxMessageBytes: UInt32 = 1_048_576

    static func run() {
        let stdin = FileHandle.standardInput
        guard let lenBytes = readExactly(stdin, 4),
              let length = decodeLength([UInt8](lenBytes)),
              length > 0, length <= maxMessageBytes,
              let body = readExactly(stdin, Int(length)) else {
            return
        }
        // 只校验「是 JSON 对象」这一形状,不解析业务。
        let isJSONObject = (try? JSONSerialization.jsonObject(with: body)) is [String: Any]
        guard isJSONObject else {
            respond(ok: false)   // SC7:不回显 body
            return
        }
        let ok = ClaudeWebStore.writeRaw(body)
        respond(ok: ok)
    }

    // MARK: - framing(internal，供单测直接验证）

    /// 4 字节小端 → UInt32。
    static func decodeLength(_ b: [UInt8]) -> UInt32? {
        guard b.count == 4 else { return nil }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    /// 一条出站 native message = 4 字节小端长度前缀 + JSON body。
    static func frame(_ body: Data) -> Data {
        let n = UInt32(body.count)
        var out = Data([UInt8(n & 0xff), UInt8((n >> 8) & 0xff),
                        UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff)])
        out.append(body)
        return out
    }

    // MARK: - private

    /// 回 `{"ok":true|false}` —— 让扩展侧不因「host 无响应」误判。
    private static func respond(ok: Bool) {
        let body = Data((ok ? #"{"ok":true}"# : #"{"ok":false}"#).utf8)
        try? FileHandle.standardOutput.write(contentsOf: frame(body))
    }

    /// FileHandle.read(upToCount:) 可能短读;循环读满 n 字节,EOF / 读不动 → nil。
    private static func readExactly(_ handle: FileHandle, _ n: Int) -> Data? {
        var buf = Data()
        buf.reserveCapacity(n)
        while buf.count < n {
            guard let chunk = try? handle.read(upToCount: n - buf.count),
                  !chunk.isEmpty else { return nil }
            buf.append(chunk)
        }
        return buf
    }
}
