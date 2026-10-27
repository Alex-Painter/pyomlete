import Foundation

/// Any JSON. A tool's input and output are the model's and the server's to
/// shape, so the phone keeps them as they came and sends them back unchanged.
nonisolated enum JSONValue: Equatable, Sendable, Codable, ExpressibleByStringLiteral {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(stringLiteral value: String) {
        self = .string(value)
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }

    var string: String? {
        if case .string(let text) = self { text } else { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// One event of the AI SDK's UI message stream, which `POST /chef/chat`
/// answers with. Only what the chat shows is kept; every other type is `.other`.
nonisolated enum ChefStreamEvent: Equatable, Sendable {
    /// The reply's id, when the server names one.
    case start(messageID: String?)
    case textStart
    case textDelta(String)
    /// A tool call began (`tool-input-start`, no input yet) or its input is complete.
    case toolInput(callID: String, name: String, input: JSONValue?, providerExecuted: Bool)
    case toolOutput(callID: String, output: JSONValue)
    case toolFailed(callID: String, error: String)
    /// The run failed. The reply so far stays.
    case failed(String)
    case other

    /// Reads one `data:` payload. Throws when it is not a JSON object with a type.
    init(payload: Data) throws {
        let event = try JSONDecoder().decode([String: JSONValue].self, from: payload)
        guard let type = event["type"]?.string else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "an event with no type"))
        }
        let callID = event["toolCallId"]?.string
        switch type {
        case "start":
            self = .start(messageID: event["messageId"]?.string)
        case "text-start":
            self = .textStart
        case "text-delta":
            self = .textDelta(event["delta"]?.string ?? "")
        case "tool-input-start", "tool-input-available":
            guard let callID, let name = event["toolName"]?.string else { self = .other; return }
            self = .toolInput(
                callID: callID, name: name, input: event["input"],
                providerExecuted: event["providerExecuted"] == .bool(true))
        case "tool-output-available":
            guard let callID else { self = .other; return }
            self = .toolOutput(callID: callID, output: event["output"] ?? .null)
        case "tool-output-error":
            guard let callID else { self = .other; return }
            self = .toolFailed(callID: callID, error: event["errorText"]?.string ?? "")
        case "error":
            self = .failed(event["errorText"]?.string ?? "Chef ran into a problem")
        default:
            self = .other
        }
    }
}

/// Splits a server-sent event stream into the payloads of its `data:` lines,
/// however the bytes are cut. An event ends at a blank line; text is decoded
/// only once its event is whole, so a character split across chunks survives.
nonisolated struct ServerSentEvents {
    enum Payload: Equatable {
        case data(Data)
        /// `data: [DONE]`: nothing follows.
        case done
    }

    private var buffer = Data()

    /// The payloads that `chunk` completes, in order.
    mutating func feed(_ chunk: Data) -> [Payload] {
        // A carriage return never appears unescaped inside a JSON payload, so line ends can be normalised.
        buffer.append(contentsOf: chunk.filter { $0 != UInt8(ascii: "\r") })
        var payloads: [Payload] = []
        let blankLine = Data("\n\n".utf8)
        while let end = buffer.range(of: blankLine) {
            let event = buffer[buffer.startIndex..<end.lowerBound]
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            for line in event.split(separator: UInt8(ascii: "\n")) where line.starts(with: Data("data: ".utf8)) {
                let payload = Data(line.dropFirst(6))
                payloads.append(payload == Data("[DONE]".utf8) ? .done : .data(payload))
            }
        }
        return payloads
    }
}
