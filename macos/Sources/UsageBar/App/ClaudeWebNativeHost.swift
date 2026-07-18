import Foundation

/// Chrome Native Messaging host —— Chrome 以 argv[1]=扩展 origin 拉起主 binary,`main.swift` 据此
/// 进入本模式。协议:stdin 先 4-byte 长度(小端)+ JSON body;回一条同格式的 ack。
///
/// 本 host **只做**:校验入站是合法 JSON 对象 → 分派 → ack → 退出。不解析业务、不发网络、不起 AppKit。
/// 碰两个文件:
/// - 写 `claude-web.json`(收到 usage payload 时,交给 app 显示)——见 `ClaudeWebStore`;
/// - 读 `claude-web-control.json`(app 写的控制配置)并**原样**回传扩展 —— ADR 0011 反向控制通道。
///
/// 消息分派:`{"type":"poll"}` = 只拉配置的心跳(不写 usage);其余(usage payload)= 写 `claude-web.json`。
/// 无论哪种,ack 都带回当前 control(`{"ok":<bool>,"control":<json>|null}`)。
///
/// SC7:解析失败绝不记录原始 stdin 字节。control 文件是 app 自写的配置(paused/interval/nonce/ts),
/// 无 cookie/凭证;host 只做「是合法 JSON」形状校验后原样内嵌,不解析其字段。
enum ClaudeWebNativeHost {
    /// Chrome 单条 native message 上限 ~1MB;拒绝异常长度,防内存滥用。
    static let maxMessageBytes: UInt32 = 1_048_576

    static func run() {
        let stdin = FileHandle.standardInput
        guard let lenBytes = readExactly(stdin, 4),
              let length = decodeLength([UInt8](lenBytes)),
              length > 0, length <= maxMessageBytes,
              let body = readExactly(stdin, Int(length)) else {
            return
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            // 非法 JSON 对象 → ok:false(仍带 control,让扩展照常读配置)。SC7:不回显 body。
            write(responseBody(ok: false, controlBytes: loadValidControlBytes()))
            return
        }
        // poll = 只拉配置,不写 usage;否则视为 usage payload → 写 claude-web.json(不变)。
        let ok = isPollMessage(obj) ? true : ClaudeWebStore.writeRaw(body)
        write(responseBody(ok: ok, controlBytes: loadValidControlBytes()))
    }

    // MARK: - dispatch / framing / response(internal，供单测直接验证）

    /// 消息是否为「只拉配置」的心跳(不写 usage)。
    static func isPollMessage(_ obj: [String: Any]) -> Bool {
        (obj["type"] as? String) == "poll"
    }

    /// 组装出站 body:`{"ok":<bool>,"control":<control-json>|null}`。
    /// `controlBytes` 已确保是合法 JSON(见 `loadValidControlBytes`),原样内嵌;nil → `null`。
    /// 因此 response 始终是合法 JSON —— 空/半截/畸形的 control 文件不会污染 ack(含 usage-sync 的 ack)。
    static func responseBody(ok: Bool, controlBytes: Data?) -> Data {
        var out = Data(#"{"ok":"#.utf8)
        out.append(Data((ok ? "true" : "false").utf8))
        out.append(Data(#","control":"#.utf8))
        out.append(controlBytes ?? Data("null".utf8))
        out.append(Data("}".utf8))
        return out
    }

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

    /// 读 control 文件原始字节;仅当解析为合法 JSON 才回传,否则 nil(缺失/空/半截/畸形 → `control:null`)。
    private static func loadValidControlBytes() -> Data? {
        guard let data = try? Data(contentsOf: ClaudeWebControlStore.fileURL),
              (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return data
    }

    /// 写一条出站 native message 到 stdout。`FileHandle` = 直接 write(2)、无 stdio 缓冲,exit 前不丢字节
    /// (`sendNativeMessage` 依赖 host 退出前把整条 response 写进管道)。
    private static func write(_ body: Data) {
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
