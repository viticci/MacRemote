import Foundation

/// How an elicitation question is shown: a form, or a link to open.
enum MCPElicitationMode: String, Sendable {
    case form
    case url
}

/// The one way a bridged server's questions reach the app that made the call
/// (MCP elicitation, SPEC D82). The server implements it for each running
/// `tools/call` (`ToolCallHandoff`) and installs it as
/// `MCPElicitationRelay.current`; the bridge clients reach it only through
/// `MCPElicitationRelay.ask`, which caps, labels, and fills in what this
/// returns. Nothing here approves anything: approvals stay on the Mac.
protocol MCPElicitationAnswering: Sendable {
    /// The modes the calling app can show. Empty when nobody can answer.
    var modes: Set<MCPElicitationMode> { get }

    /// Shows `questions` (keyed `elicitation/create` request objects) to the
    /// app and waits for its answers, keyed the same way. Nil when the app
    /// cannot be asked after all; a missing key is an unanswered question.
    func answers(to questions: [String: JSONValue]) async -> [String: JSONValue]?
}

/// The bridge side of the relay: what every bridge client calls when an
/// upstream server asks a question in the middle of a tool call.
enum MCPElicitationRelay {
    /// The relay for the tool call running in this task, if any.
    @TaskLocal static var current: (any MCPElicitationAnswering)?

    static let elicitationMethod = "elicitation/create"
    /// At most this many questions are relayed at once; the rest are declined.
    static let maximumQuestions = 16
    /// A question larger than this, as JSON, is declined instead of relayed.
    static let maximumQuestionBytes = 32 * 1024
    /// At most this many rounds of questions in one bridged call; the next
    /// round ends the call.
    static let maximumRounds = 8

    /// How many rounds of questions one bridged call has asked. Each bridge
    /// call makes one and passes it to every `ask`, so the round cap holds
    /// the same way for a legacy `elicitation/create`, a modern
    /// `input_required`, and an upstream task that needs input.
    final class Rounds: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        /// Counts one more round; false once the call has had all it may.
        fileprivate func begin() -> Bool {
            lock.withLock {
                count += 1
                return count <= MCPElicitationRelay.maximumRounds
            }
        }
    }

    /// Answers every question in `questions`, which a bridged server named
    /// `server` asked, as one of the call's `rounds`. Questions the app can
    /// show go to `relay` with the server's name in front of their message,
    /// so the person can tell who is asking; nothing else in a question
    /// changes. A question nobody can answer gets `decline` when it is a form
    /// and `cancel` otherwise; one over a cap gets `decline`. A round past
    /// `maximumRounds` is not asked: it throws `tooManyRounds`, which ends
    /// the call.
    static func ask(
        _ questions: [String: JSONValue],
        server: String,
        relay: (any MCPElicitationAnswering)?,
        rounds: Rounds
    ) async throws -> [String: JSONValue] {
        guard rounds.begin() else {
            throw MCPUpstreamToolCallError.tooManyRounds(maximumRounds)
        }
        var answers = [String: JSONValue]()
        var relayed = [String: JSONValue]()
        let modes = relay?.modes ?? []
        for key in questions.keys.sorted() {
            guard let question = questions[key] else { continue }
            let mode = Self.mode(of: question)
            guard relayed.count < maximumQuestions, fitsSizeCap(question) else {
                answers[key] = answer("decline")
                continue
            }
            guard let mode, modes.contains(mode) else {
                answers[key] = unanswered(mode)
                continue
            }
            relayed[key] = labeled(question, server: server)
        }
        guard !relayed.isEmpty else { return answers }
        let received = await relay?.answers(to: relayed) ?? [:]
        for key in relayed.keys {
            answers[key] = received[key] ?? unanswered(questions[key].flatMap(Self.mode(of:)))
        }
        return answers
    }

    /// The `elicitation` client capability for the modes `relay` can show,
    /// or nil when it shows none.
    static func capability(for relay: (any MCPElicitationAnswering)?) -> [String: Any]? {
        guard let modes = relay?.modes, !modes.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: modes.map { ($0.rawValue, [String: Any]()) })
    }

    /// The modes an app declared in its `elicitation` capability. An empty
    /// object means form only, as the schema says.
    static func modes(declaredIn capabilities: JSONValue) -> Set<MCPElicitationMode> {
        guard let elicitation = capabilities.objectValue?["elicitation"]?.objectValue else { return [] }
        let declared = Set(elicitation.keys.compactMap(MCPElicitationMode.init(rawValue:)))
        return elicitation.isEmpty ? [.form] : declared
    }

    /// A question's mode; a question without one is a form. Nil for a
    /// method other than `elicitation/create` or a mode MacRemote does not know.
    static func mode(of question: JSONValue) -> MCPElicitationMode? {
        guard let object = question.objectValue,
              object["method"] == .string(elicitationMethod) else { return nil }
        guard let mode = object["params"]?.objectValue?["mode"] else { return .form }
        guard case .string(let name) = mode else { return nil }
        return MCPElicitationMode(rawValue: name)
    }

    /// An answer an app sent, reduced to what the upstream needs: its
    /// action, and its content when it accepted. Nil when it is not an answer.
    static func normalizedAnswer(_ value: JSONValue) -> JSONValue? {
        guard let object = value.objectValue,
              case .string(let action) = object["action"],
              ["accept", "decline", "cancel"].contains(action) else { return nil }
        var answer = ["action": JSONValue.string(action)]
        if action == "accept", let content = object["content"], content.objectValue != nil {
            answer["content"] = content
        }
        return .object(answer)
    }

    private static func fitsSizeCap(_ question: JSONValue) -> Bool {
        guard let data = try? JSONSerialization.checkedData(withJSONObject: question.anyValue) else { return false }
        return data.count <= maximumQuestionBytes
    }

    private static func unanswered(_ mode: MCPElicitationMode?) -> JSONValue {
        answer(mode == .form ? "decline" : "cancel")
    }

    private static func answer(_ action: String) -> JSONValue {
        .object(["action": .string(action)])
    }

    private static func labeled(_ question: JSONValue, server: String) -> JSONValue {
        guard var object = question.objectValue else { return question }
        var params = object["params"]?.objectValue ?? [:]
        let message: String
        if case .string(let text) = params["message"] {
            message = text
        } else {
            message = ""
        }
        params["message"] = .string("[\(server.prefix(64))] \(message)")
        object["params"] = .object(params)
        return .object(object)
    }
}

/// A modern upstream `tools/call` followed to its end (SPEC D82). The
/// upstream may answer with a complete result, with `input_required` (MacRemote
/// asks the questions and sends the call again with the answers), or with a
/// task of its own (MacRemote polls it, answers its questions with
/// `tasks/update`, and cancels it if the call ends early). A task's first
/// answer is only a handle: its status, result, and questions come from
/// `tasks/get`. The HTTP and stdio bridges send the requests; this type
/// decides what comes next.
struct MCPUpstreamToolCall {
    /// What the bridge does after a response.
    enum Next {
        /// The call's tool result.
        case finished([String: Any])
        /// Ask these questions, then send `request(answering:)`.
        case ask([String: JSONValue])
        /// Wait this long, then send `pollRequest()`.
        case poll(after: Duration)
    }

    private let toolCall: [String: Any]
    private var lastMethod = "tools/call"
    private var taskID: String?
    private var requestState: String?
    /// An upstream task's question keys already answered; a poll can list
    /// them again before the server has read the answer.
    private var answeredKeys = Set<String>()

    /// `toolCall` is the `tools/call` params: `name` and `arguments`.
    init(toolCall: [String: Any]) {
        self.toolCall = toolCall
    }

    /// What to do after `result`, the `result` object of the response to the
    /// last request.
    mutating func next(after result: [String: Any]) throws -> Next {
        let resultType = result["resultType"] as? String
        switch lastMethod {
        case "tasks/update":
            return .poll(after: .zero)
        case "tasks/get":
            guard resultType == "complete" else {
                throw MCPUpstreamToolCallError.invalid("tasks/get returned resultType \(resultType ?? "nothing")")
            }
            return try taskStep(result)
        default:
            switch resultType {
            case "complete":
                return .finished(result)
            case "input_required":
                // The relay counts the rounds (`MCPElicitationRelay.ask`).
                requestState = result["requestState"] as? String
                return .ask(try Self.questions(in: result))
            case "task":
                guard let id = result["taskId"] as? String, !id.isEmpty else {
                    throw MCPUpstreamToolCallError.invalid("a task result carried no taskId")
                }
                taskID = id
                // Read the task at once, unless it says it is still working.
                return .poll(after: result["status"] as? String == "working" ? Self.pollInterval(result) : .zero)
            default:
                throw MCPUpstreamToolCallError.invalid("unknown resultType \(resultType ?? "(missing)")")
            }
        }
    }

    /// The request that delivers `answers`: `tasks/update` for an upstream
    /// task, otherwise the same `tools/call` again with the upstream's
    /// `requestState` echoed exactly.
    mutating func request(answering answers: [String: JSONValue]) -> (method: String, params: [String: Any]) {
        let responses = answers.mapValues(\.anyValue)
        if let taskID {
            answeredKeys.formUnion(answers.keys)
            lastMethod = "tasks/update"
            return ("tasks/update", ["taskId": taskID, "inputResponses": responses])
        }
        lastMethod = "tools/call"
        var params = toolCall
        params["inputResponses"] = responses
        params["requestState"] = requestState
        return ("tools/call", params)
    }

    mutating func pollRequest() -> (method: String, params: [String: Any]) {
        lastMethod = "tasks/get"
        return ("tasks/get", ["taskId": taskID ?? ""])
    }

    /// `tasks/cancel` for the upstream task while one may still be running.
    /// Send it when the call ends any other way than through the task.
    var cancelRequest: (method: String, params: [String: Any])? {
        taskID.map { ("tasks/cancel", ["taskId": $0]) }
    }

    private mutating func taskStep(_ task: [String: Any]) throws -> Next {
        switch task["status"] as? String {
        case "completed":
            guard let result = task["result"] as? [String: Any] else {
                throw MCPUpstreamToolCallError.invalid("a completed task carried no result")
            }
            taskID = nil
            return .finished(result)
        case "failed":
            taskID = nil
            let error = task["error"] as? [String: Any]
            throw MCPUpstreamToolCallError.taskEnded(
                error?["message"] as? String ?? task["statusMessage"] as? String ?? "the task failed"
            )
        case "cancelled":
            taskID = nil
            throw MCPUpstreamToolCallError.taskEnded(task["statusMessage"] as? String ?? "the task was cancelled")
        case "input_required":
            let questions = try Self.questions(in: task).filter { !answeredKeys.contains($0.key) }
            return questions.isEmpty ? .poll(after: Self.pollInterval(task)) : .ask(questions)
        case "working":
            return .poll(after: Self.pollInterval(task))
        default:
            throw MCPUpstreamToolCallError.invalid("a task had no known status")
        }
    }

    /// The upstream's questions. Only `elicitation/create` is relayed;
    /// anything else ends the call.
    private static func questions(in result: [String: Any]) throws -> [String: JSONValue] {
        let requests = result["inputRequests"] as? [String: Any] ?? [:]
        var questions = [String: JSONValue]()
        for (key, request) in requests {
            let method = (request as? [String: Any])?["method"] as? String
            guard method == MCPElicitationRelay.elicitationMethod,
                  let question = JSONValue.fromJSONObject(request) else {
                throw MCPUpstreamToolCallError.unrelayedRequest(method ?? "an unknown request")
            }
            questions[key] = question
        }
        return questions
    }

    /// The upstream's `pollIntervalMs`, kept between a quarter second and
    /// ten seconds; one second when it sends none.
    private static func pollInterval(_ task: [String: Any]) -> Duration {
        let milliseconds = (task["pollIntervalMs"] as? NSNumber)?.intValue ?? 1000
        return .milliseconds(min(max(milliseconds, 250), 10_000))
    }
}

enum MCPUpstreamToolCallError: LocalizedError {
    case invalid(String)
    case tooManyRounds(Int)
    case taskEnded(String)
    case unrelayedRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail):
            "Invalid upstream MCP result: \(detail)."
        case .tooManyRounds(let rounds):
            "The upstream MCP server asked for input more than \(rounds) times in one call."
        case .taskEnded(let message):
            "The upstream MCP server's task ended without a result: \(message)"
        case .unrelayedRequest(let method):
            "The upstream MCP server asked for \(method), which MacRemote does not relay to apps."
        }
    }
}
