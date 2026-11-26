import Foundation
import Security

/// What one `tools/call` produced: the result it returns, or the JSON-RPC
/// error it answers with. Built once and never changed, so it can be handed
/// from the task that ran the call to whoever reports it.
enum ToolCallLogicalResult: @unchecked Sendable {
    case result([String: Any])
    case jsonRPCError(code: Int, message: String, data: [String: Any]?)
}

/// Where a task stands (MCP Tasks extension, SPEC D81). `working` and
/// `inputRequired` may move to any state; `completed`, `failed`, and
/// `cancelled` are final and never change. `advanced(to:)` is the only place
/// that rule lives.
enum ToolCallTaskStatus: @unchecked Sendable {
    case working(message: String?)
    /// A bridged server asked questions the app must answer with
    /// `tasks/update` (SPEC D82), keyed as the app sees them.
    case inputRequired(requests: [String: JSONValue])
    /// The finished `tools/call` result, including one with `isError: true`.
    case completed(result: [String: Any])
    /// Only for what would have been a JSON-RPC error.
    case failed(code: Int, message: String, data: [String: Any]?)
    case cancelled(message: String?)

    var isFinal: Bool {
        switch self {
        case .working, .inputRequired: false
        case .completed, .failed, .cancelled: true
        }
    }

    /// The status after a move to `next`, or nil when the move is not allowed.
    func advanced(to next: ToolCallTaskStatus) -> ToolCallTaskStatus? {
        isFinal ? nil : next
    }

    /// The final status for what a call produced.
    init(finishedWith outcome: ToolCallLogicalResult) {
        switch outcome {
        case .result(let result):
            self = .completed(result: result)
        case .jsonRPCError(let code, let message, let data):
            self = .failed(code: code, message: message, data: data)
        }
    }
}

/// A task as an app sees it at one moment.
struct ToolCallTask: Sendable {
    let id: String
    let status: ToolCallTaskStatus
    let createdAt: Date
    let lastUpdatedAt: Date
    let ttlMs: Int
    let pollIntervalMs: Int
}

/// The server's tasks, in memory only. A task belongs to the app that made
/// it; every other caller is told it does not exist. A finished task is kept
/// for an hour so its app can collect the result, then dropped. Quitting
/// MacRemote or stopping the server closes the store: every running task
/// ends, so does every call still in its grace period, and no call becomes a
/// task after that.
///
/// The store also holds calls answered with `input_required` (SPEC D82):
/// each waits under a `requestState` handle until its app sends the call
/// again, for at most `heldCallLifetime`.
final class ToolCallTaskStore: @unchecked Sendable {
    static let maximumRunningPerApp = 8
    static let maximumRunning = 32
    /// Finished tasks count here too. At the limit the oldest finished task
    /// is dropped early; running tasks are already capped well below it.
    static let maximumKept = 128
    static let retention: TimeInterval = 60 * 60

    /// How long a call runs inside its request before it becomes a task.
    let grace: Duration
    /// How long a `requestState` handle works.
    let heldCallLifetime: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var records = [String: Record]()
    private var heldCalls = [String: HeldCall]()
    /// Calls still in their request that become tasks when their grace
    /// period ends.
    private var callsInGracePeriod = [ObjectIdentifier: ToolCallHandoff]()
    private var closed = false

    private struct Record {
        let id: String
        let ownerID: String
        let toolID: String
        var status: ToolCallTaskStatus
        let createdAt: Date
        var lastUpdatedAt: Date
        let timeoutSeconds: TimeInterval
        let work: Task<Void, Never>
        /// Delivers an app's `tasks/update` answers to the running call.
        let respond: @Sendable ([String: JSONValue]) -> Void
        /// Set once the task is final.
        var dropAt: Date?
    }

    /// A call waiting for its app to send it again with answers. The handle
    /// is bound to the app, the tool name, and the arguments.
    private struct HeldCall {
        let ownerID: String
        let toolName: String
        let arguments: JSONValue
        let handoff: ToolCallHandoff
        let expiresAt: Date
    }

    init(
        grace: Duration = .seconds(20),
        heldCallLifetime: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.grace = grace
        self.heldCallLifetime = heldCallLifetime
        self.now = now
    }

    /// Records a running call as a task owned by `ownerID`, or returns nil
    /// when the store is closed or that app or the server already has as
    /// many as allowed. The task can be read as soon as this returns.
    func create(
        ownerID: String,
        toolID: String,
        timeoutSeconds: TimeInterval,
        status: ToolCallTaskStatus,
        work: Task<Void, Never>,
        respond: @escaping @Sendable ([String: JSONValue]) -> Void
    ) -> ToolCallTask? {
        lock.withLock {
            guard !closed else { return nil }
            let date = now()
            dropExpired(at: date)
            let running = records.values.filter { !$0.status.isFinal }
            guard running.count < Self.maximumRunning,
                  running.filter({ $0.ownerID == ownerID }).count < Self.maximumRunningPerApp else {
                return nil
            }
            if records.count >= Self.maximumKept,
               let oldest = records.values
                .filter({ $0.status.isFinal })
                .min(by: { $0.lastUpdatedAt < $1.lastUpdatedAt }) {
                records[oldest.id] = nil
            }
            let record = Record(
                id: Self.newHandle(),
                ownerID: ownerID,
                toolID: toolID,
                status: status,
                createdAt: date,
                lastUpdatedAt: date,
                timeoutSeconds: timeoutSeconds,
                work: work,
                respond: respond
            )
            records[record.id] = record
            return snapshot(of: record, at: date)
        }
    }

    /// The task, or nil when it is unknown, expired, or another app's.
    func task(id: String, ownerID: String) -> ToolCallTask? {
        lock.withLock {
            let date = now()
            dropExpired(at: date)
            guard let record = records[id], record.ownerID == ownerID else { return nil }
            return snapshot(of: record, at: date)
        }
    }

    /// Moves a task to `status`. A move the status rules do not allow, such
    /// as a cancelled call reporting its result, changes nothing.
    func update(id: String, to status: ToolCallTaskStatus) {
        lock.withLock { advance(id: id, to: status, at: now()) }
    }

    /// Hands an app's `tasks/update` answers to its running call. Answers to
    /// questions that are not waiting are ignored. False when the task is
    /// unknown, expired, or another app's.
    func respond(id: String, ownerID: String, responses: [String: JSONValue]) -> Bool {
        let respond = lock.withLock {
            dropExpired(at: now())
            return records[id].flatMap { $0.ownerID == ownerID ? $0.respond : nil }
        }
        respond?(responses)
        return respond != nil
    }

    /// Cancels a running task and stops its work, which ends any process it
    /// started. A finished task is left as it is. False when the task is
    /// unknown, expired, or another app's.
    func cancel(id: String, ownerID: String) -> Bool {
        let work: Task<Void, Never>? = lock.withLock {
            let date = now()
            dropExpired(at: date)
            guard let record = records[id], record.ownerID == ownerID else { return nil }
            advance(id: id, to: .cancelled(message: "Cancelled by the app."), at: date)
            return record.work
        }
        guard let work else { return false }
        work.cancel()
        return true
    }

    /// Whether `close()` ran. A call that would become a task or be held in
    /// a closed store is stopped instead.
    var isClosed: Bool {
        lock.withLock { closed }
    }

    /// Cancels every running task, every held call, and every call in its
    /// grace period, and admits no new ones, in one step. Used when the
    /// server stops: nobody can collect their results after that.
    func close() {
        let (works, held, waiting): ([Task<Void, Never>], [HeldCall], [ToolCallHandoff]) = lock.withLock {
            closed = true
            let date = now()
            let running = records.values.filter { !$0.status.isFinal }
            for record in running {
                advance(id: record.id, to: .cancelled(message: "MacRemote stopped."), at: date)
            }
            defer {
                heldCalls = [:]
                callsInGracePeriod = [:]
            }
            return (running.map(\.work), Array(heldCalls.values), Array(callsInGracePeriod.values))
        }
        for work in works { work.cancel() }
        for call in held { call.handoff.abandon(stoppingWork: true) }
        for handoff in waiting { handoff.cancelUnlessTask() }
    }

    /// Runs `body` while `handoff`, a call that becomes a task when its grace
    /// period ends, waits in its request. Closing the store stops such a
    /// call at once instead of when its grace period ends.
    func whileInGracePeriod<Value: Sendable>(_ handoff: ToolCallHandoff, _ body: () async -> Value) async -> Value {
        let key = ObjectIdentifier(handoff)
        let admitted = lock.withLock {
            guard !closed else { return false }
            callsInGracePeriod[key] = handoff
            return true
        }
        if !admitted { handoff.cancelUnlessTask() }
        defer { lock.withLock { callsInGracePeriod[key] = nil } }
        return await body()
    }

    /// Holds `handoff`, whose request is about to be answered with
    /// `input_required`, and returns the `requestState` handle the app sends
    /// back; nil when the store is closed. A call not resumed in time is
    /// abandoned: its questions are answered `cancel`.
    func hold(_ handoff: ToolCallHandoff, ownerID: String, toolName: String, arguments: JSONValue) -> String? {
        let handle = Self.newHandle()
        let admitted: Bool = lock.withLock {
            guard !closed else { return false }
            heldCalls[handle] = HeldCall(
                ownerID: ownerID,
                toolName: toolName,
                arguments: arguments,
                handoff: handoff,
                expiresAt: now().addingTimeInterval(heldCallLifetime)
            )
            return true
        }
        guard admitted else { return nil }
        let lifetime = heldCallLifetime
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            self?.expire(handle)
        }
        return handle
    }

    /// The held call for `requestState`, which then stops working: each
    /// handle is good for one round. Nil when it is unknown, expired, or
    /// bound to another app, tool name, or arguments.
    func resume(requestState: String, ownerID: String, toolName: String, arguments: JSONValue) -> ToolCallHandoff? {
        lock.withLock {
            guard let call = heldCalls[requestState],
                  call.expiresAt > now(),
                  call.ownerID == ownerID,
                  call.toolName == toolName,
                  call.arguments == arguments else { return nil }
            heldCalls[requestState] = nil
            return call.handoff
        }
    }

    private func expire(_ handle: String) {
        let call = lock.withLock { heldCalls.removeValue(forKey: handle) }
        call?.handoff.abandon(stoppingWork: false)
    }

    /// Call with the lock held.
    private func advance(id: String, to status: ToolCallTaskStatus, at date: Date) {
        guard var record = records[id],
              let next = record.status.advanced(to: status) else { return }
        record.status = next
        record.lastUpdatedAt = date
        if next.isFinal {
            record.dropAt = date.addingTimeInterval(Self.retention)
        }
        records[id] = record
    }

    private func dropExpired(at date: Date) {
        records = records.filter { _, record in
            guard let dropAt = record.dropAt else { return true }
            return dropAt > date
        }
    }

    /// `ttlMs` counts from creation: while the call runs, its whole timeout
    /// plus the hour its result is kept; once it finishes, exactly when it
    /// will be dropped. Apps are asked to poll every 2 seconds for a task's
    /// first minute and every 10 seconds after.
    private func snapshot(of record: Record, at date: Date) -> ToolCallTask {
        let expiry = record.dropAt
            ?? record.createdAt.addingTimeInterval(record.timeoutSeconds + Self.retention)
        let age = date.timeIntervalSince(record.createdAt)
        return ToolCallTask(
            id: record.id,
            status: record.status,
            createdAt: record.createdAt,
            lastUpdatedAt: record.lastUpdatedAt,
            ttlMs: Int((expiry.timeIntervalSince(record.createdAt) * 1000).rounded()),
            pollIntervalMs: age < 60 ? 2000 : 10_000
        )
    }

    /// 256 random bits as 64 hex characters: unguessable, printable, no
    /// spaces. Used for task ids and `requestState` handles, and for
    /// uploads' handles (`FileUploadStore`).
    static func newHandle() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed.")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One `tools/call` on its way to an answer. The request waits in `answer()`
/// for whichever comes first: the call finishing, which answers the request
/// as it always has, or `becomeTask`, which answers it with a task and hands
/// everything the call does afterwards to the task store. Until it is a task,
/// `cancelUnlessTask` stops the call, as a closed connection always has.
///
/// It is also the call's `MCPElicitationAnswering` (SPEC D82): a bridged
/// server's questions go where `QuestionDelivery` says. In an app with the
/// Tasks extension the call becomes a task showing `input_required`, and
/// `tasks/update` answers it. In an app with only elicitation the request is
/// answered with `input_required` and a `requestState`; the call waits, held
/// in the task store, until the app sends the call again (`resume(with:)`),
/// and that request then waits in `answer()` in turn.
final class ToolCallHandoff: MCPElicitationAnswering, @unchecked Sendable {
    enum Answer: Sendable {
        case result(ToolCallLogicalResult)
        case task(ToolCallTask)
        /// The app must answer these and send the call again with `requestState`.
        case inputRequired(requests: [String: JSONValue], requestState: String)
    }

    /// Where the call's questions go, fixed by the request that started it.
    enum QuestionDelivery: Sendable {
        /// Nobody can answer: the bridge declines or cancels at once.
        case none
        /// The app declared the Tasks extension.
        case task(TaskPlacement)
        /// The app declared elicitation but not the Tasks extension.
        case requestState(store: ToolCallTaskStore, ownerID: String, toolName: String, arguments: JSONValue)
    }

    private enum Phase {
        case inRequest
        /// The request went away first; the call is stopping.
        case cancelled
        case task(id: String, store: ToolCallTaskStore)
        /// Answered with `input_required`; no request waits until the app
        /// sends the call again.
        case held
        case answered
        /// Held, and the app never came back. The result is dropped.
        case abandoned
    }

    /// The questions waiting for answers, by the keys the app sees.
    private struct Round {
        var waiting: [String: (upstreamKey: String, question: JSONValue)]
        var answers = [String: JSONValue]()
        let continuation: CheckedContinuation<[String: JSONValue]?, Never>

        var requests: [String: JSONValue] { waiting.mapValues { $0.question } }
    }

    /// The modes declared by the request now waiting on the call: a retry
    /// with `requestState` brings its own.
    var modes: Set<MCPElicitationMode> {
        lock.withLock { currentModes }
    }
    private var currentModes: Set<MCPElicitationMode>
    private let delivery: QuestionDelivery
    private let lock = NSLock()
    private var phase = Phase.inRequest
    private var work: Task<Void, Never>?
    private var statusMessage: String?
    private var answerValue: Answer?
    private var waiter: CheckedContinuation<Answer, Never>?
    private var round: Round?
    /// Numbers the app-facing keys, so none repeats in the call's life.
    private var questionCount = 0

    init(modes: Set<MCPElicitationMode> = [], delivery: QuestionDelivery = .none) {
        if case .none = delivery {
            currentModes = []
        } else {
            currentModes = modes
        }
        self.delivery = delivery
    }

    /// Where a call that is a task from its first moment is kept.
    struct TaskPlacement: Sendable {
        let store: ToolCallTaskStore
        let ownerID: String
        let toolID: String
        let timeoutSeconds: TimeInterval
    }

    /// Starts the call. It reports what it is waiting for through the
    /// closure it is given, which a task shows as its status message. With
    /// `asTask`, the call is a task before it can finish, so even a call that
    /// ends at once answers with a task (SPEC D81).
    func start(
        asTask placement: TaskPlacement? = nil,
        _ operation: @escaping @Sendable (_ report: @escaping @Sendable (String) -> Void) async -> ToolCallLogicalResult
    ) {
        // Under the lock, so `finish` cannot run before the task exists.
        let effects: () -> Void = lock.withLock {
            let work = Task {
                let outcome = await operation { message in self.report(message) }
                self.finish(outcome)
            }
            self.work = work
            guard let placement else { return {} }
            return becomeTaskLocked(placement)
        }
        effects()
    }

    /// Waits for the request's answer.
    func answer() async -> Answer {
        await withCheckedContinuation { continuation in
            let ready: Answer? = lock.withLock {
                if let answerValue { return answerValue }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Makes the running call a task in `store`. Does nothing when the call
    /// already finished, its request went away, or the store is full; the
    /// call then answers in its request. A closed store (the server stopped)
    /// stops the call instead.
    func becomeTask(_ placement: TaskPlacement) {
        let effects = lock.withLock { becomeTaskLocked(placement) }
        effects()
    }

    /// Call with the lock held; run what it returns after.
    private func becomeTaskLocked(_ placement: TaskPlacement) -> () -> Void {
        guard case .inRequest = phase, let work else { return {} }
        guard let task = placement.store.create(
            ownerID: placement.ownerID,
            toolID: placement.toolID,
            timeoutSeconds: placement.timeoutSeconds,
            status: .working(message: statusMessage),
            work: work,
            respond: { [weak self] in self?.respond($0) }
        ) else {
            return stopIfClosed(placement.store)
        }
        phase = .task(id: task.id, store: placement.store)
        let resume = settle(.task(task))
        return { resume.map { $0.0.resume(returning: $0.1) } }
    }

    /// Stops the call while it still answers in its request. A task is
    /// stopped only through its own cancel.
    func cancelUnlessTask() {
        let work: Task<Void, Never>? = lock.withLock {
            guard case .inRequest = phase else { return nil }
            phase = .cancelled
            return self.work
        }
        work?.cancel()
    }

    // MARK: Questions (SPEC D82)

    func answers(to questions: [String: JSONValue]) async -> [String: JSONValue]? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let effects = lock.withLock { open(questions, continuation: continuation) }
                effects()
            }
        } onCancel: {
            let effects = lock.withLock { closeRound(with: nil) }
            effects()
        }
    }

    /// The app sent the held call again: deliver its answers and wait in
    /// `answer()` for what comes next. From now on questions go to this
    /// request only in the `modes` it declared. A call that finished while
    /// held answers with its result.
    func resume(with responses: [String: JSONValue], modes: Set<MCPElicitationMode>) {
        let effects: () -> Void = lock.withLock {
            guard case .held = phase else { return {} }
            phase = .inRequest
            answerValue = nil
            currentModes = modes
            return record(responses)
        }
        effects()
    }

    /// The app never came back to a held call: every waiting question is
    /// answered `cancel`, so the upstream is told, and the result is dropped.
    /// `stoppingWork` also stops the call, as stopping the server does.
    func abandon(stoppingWork: Bool) {
        let (effects, work): (() -> Void, Task<Void, Never>?) = lock.withLock {
            guard case .held = phase else { return ({}, nil) }
            phase = .abandoned
            let cancelled = round.map { round in
                round.waiting.values.reduce(into: round.answers) {
                    $0[$1.upstreamKey] = .object(["action": .string("cancel")])
                }
            }
            return (closeRound(with: cancelled), stoppingWork ? self.work : nil)
        }
        effects()
        work?.cancel()
    }

    /// Answers from `tasks/update`.
    private func respond(_ responses: [String: JSONValue]) {
        let effects = lock.withLock { record(responses) }
        effects()
    }

    /// Opens a round for `questions` and shows it to the app. Call with the
    /// lock held; run what it returns after.
    private func open(
        _ questions: [String: JSONValue],
        continuation: CheckedContinuation<[String: JSONValue]?, Never>
    ) -> () -> Void {
        guard round == nil, !Task.isCancelled else {
            return { continuation.resume(returning: nil) }
        }
        var waiting = [String: (upstreamKey: String, question: JSONValue)]()
        for key in questions.keys.sorted() {
            questionCount += 1
            waiting["q\(questionCount)"] = (key, questions[key] ?? .null)
        }
        let opened = Round(waiting: waiting, continuation: continuation)
        let requests = opened.requests

        switch (phase, delivery) {
        case (.inRequest, .task(let placement)):
            guard let work,
                  let task = placement.store.create(
                    ownerID: placement.ownerID,
                    toolID: placement.toolID,
                    timeoutSeconds: placement.timeoutSeconds,
                    status: .inputRequired(requests: requests),
                    work: work,
                    respond: { [weak self] in self?.respond($0) }
                  ) else {
                let stop = stopIfClosed(placement.store)
                return { continuation.resume(returning: nil); stop() }
            }
            phase = .task(id: task.id, store: placement.store)
            round = opened
            let resume = settle(.task(task))
            return { resume.map { $0.0.resume(returning: $0.1) } }
        case (.task(let id, let store), .task):
            round = opened
            return { store.update(id: id, to: .inputRequired(requests: requests)) }
        case (.inRequest, .requestState(let store, let ownerID, let toolName, let arguments)):
            guard let handle = store.hold(self, ownerID: ownerID, toolName: toolName, arguments: arguments) else {
                let stop = stopIfClosed(store)
                return { continuation.resume(returning: nil); stop() }
            }
            phase = .held
            round = opened
            let resume = settle(.inputRequired(requests: requests, requestState: handle))
            return { resume.map { $0.0.resume(returning: $0.1) } }
        default:
            return { continuation.resume(returning: nil) }
        }
    }

    /// Records the app's answers to the open round. When every question has
    /// one, the round closes and the call carries on; otherwise the app is
    /// shown the questions still waiting. Call with the lock held.
    private func record(_ responses: [String: JSONValue]) -> () -> Void {
        guard var current = round else { return {} }
        for (key, value) in responses {
            guard let entry = current.waiting[key],
                  let answer = MCPElicitationRelay.normalizedAnswer(value) else { continue }
            current.answers[entry.upstreamKey] = answer
            current.waiting[key] = nil
        }
        if case .inRequest = phase, case .requestState = delivery {
            // A retry is asked again only in the modes it declared; the
            // relay tells the upstream no for the questions dropped here.
            current.waiting = current.waiting.filter { _, entry in
                MCPElicitationRelay.mode(of: entry.question).map(currentModes.contains) ?? false
            }
        }
        round = current
        guard current.waiting.isEmpty else {
            let requests = current.requests
            switch (phase, delivery) {
            case (.task(let id, let store), _):
                return { store.update(id: id, to: .inputRequired(requests: requests)) }
            case (.inRequest, .requestState(let store, let ownerID, let toolName, let arguments)):
                guard let handle = store.hold(self, ownerID: ownerID, toolName: toolName, arguments: arguments) else {
                    let stop = stopIfClosed(store)
                    let close = closeRound(with: nil)
                    return { close(); stop() }
                }
                phase = .held
                let resume = settle(.inputRequired(requests: requests, requestState: handle))
                return { resume.map { $0.0.resume(returning: $0.1) } }
            default:
                return {}
            }
        }
        return closeRound(with: current.answers)
    }

    /// After `store` refused a task or a hold: when the server stopped, the
    /// call stops too, and its request gets the cancellation. Call with the
    /// lock held; run what it returns after.
    private func stopIfClosed(_ store: ToolCallTaskStore) -> () -> Void {
        guard store.isClosed, let work else { return {} }
        phase = .cancelled
        return { work.cancel() }
    }

    /// Ends the open round with `answers` (nil: nobody answered) and puts a
    /// task back to working. Call with the lock held.
    private func closeRound(with answers: [String: JSONValue]?) -> () -> Void {
        guard let closing = round else { return {} }
        round = nil
        let message = statusMessage
        var target: (String, ToolCallTaskStore)?
        if case .task(let id, let store) = phase { target = (id, store) }
        return { [target] in
            if let (id, store) = target {
                store.update(id: id, to: .working(message: message))
            }
            closing.continuation.resume(returning: answers)
        }
    }

    // MARK: Reporting and finishing

    private func report(_ message: String) {
        let target: (String, ToolCallTaskStore)? = lock.withLock {
            statusMessage = message
            guard case .task(let id, let store) = phase else { return nil }
            return (id, store)
        }
        if let (id, store) = target {
            store.update(id: id, to: .working(message: message))
        }
    }

    private func finish(_ outcome: ToolCallLogicalResult) {
        enum Next { case resume(CheckedContinuation<Answer, Never>, Answer), store(String, ToolCallTaskStore), nothing }
        let next: Next = lock.withLock {
            switch phase {
            case .inRequest, .cancelled:
                phase = .answered
                return settle(.result(outcome)).map { .resume($0.0, $0.1) } ?? .nothing
            case .held:
                // Kept for the app's next request with its `requestState`.
                phase = .answered
                answerValue = .result(outcome)
                return .nothing
            case .task(let id, let store):
                return .store(id, store)
            case .answered, .abandoned:
                return .nothing
            }
        }
        switch next {
        case .resume(let continuation, let answer):
            continuation.resume(returning: answer)
        case .store(let id, let store):
            store.update(id: id, to: ToolCallTaskStatus(finishedWith: outcome))
        case .nothing:
            break
        }
    }

    /// Records the answer; returns the waiter to resume, outside the lock.
    private func settle(_ answer: Answer) -> (CheckedContinuation<Answer, Never>, Answer)? {
        answerValue = answer
        defer { waiter = nil }
        return waiter.map { ($0, answer) }
    }
}
