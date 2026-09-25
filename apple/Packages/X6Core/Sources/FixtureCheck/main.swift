import Foundation
import X6Core

struct Corpus: Decodable {
    struct Response: Decodable {
        struct Message: Decodable { let code: UInt16; let id: UInt32; let type: UInt8; let bodyHex: String }
        let name: String; let hex: String; let messages: [Message]
    }
    struct Request: Decodable { let command: UInt16; let id: UInt32; let sequence: UInt8; let hex: String }
    let responses: [Response]; let requests: [Request]
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw NSError(domain: "Usage: x6-fixture-check <x6-v1.1.7.json>", code: 1)
    }
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    var checks = 0
    for request in corpus.requests {
        guard let command = CameraCommand(rawValue: request.command),
              try UCD2.encode(command, id: request.id, sequence: request.sequence).hex == request.hex else {
            throw NSError(domain: "Request mismatch", code: 2)
        }
        checks += 1
    }
    for response in corpus.responses {
        let raw = try [UInt8](hex: response.hex)
        for split in 0...raw.count {
            var decoder = UCD2Decoder()
            let messages = try decoder.feed(Array(raw.prefix(split))) + decoder.feed(Array(raw.dropFirst(split)))
            guard messages.count == response.messages.count else { throw ProtocolError.invalidLength }
            for (actual, expected) in zip(messages, response.messages) {
                guard actual.code == expected.code, actual.id == expected.id,
                      actual.type == expected.type, actual.body.hex == expected.bodyHex else {
                    throw NSError(domain: "Live response mismatch: \(response.name)", code: 3)
                }
            }
            checks += 1
        }
    }
    print("PASS: \(checks) Swift/Python request and real-X6 response fragmentation checks")
} catch {
    fputs("FAILED: \(error)\n", stderr)
    exit(1)
}
