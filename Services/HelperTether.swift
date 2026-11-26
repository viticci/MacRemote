import Darwin
import Foundation

/// Stops Cloudflare's helper when the app dies without stopping it: a crash,
/// Force Quit, or a kill signal. macOS cannot tie a child process's life to
/// its parent's, so the app starts a second copy of its own executable in
/// tether mode. That copy only waits. When the app exits, it stops the helper;
/// when the helper exits first, it just exits.
enum HelperTether {
    /// First argument of a tether process. `MacRemoteMain` checks for it
    /// before any app code runs.
    static let flag = "--tether-helper"

    enum Outcome: Equatable {
        /// The app exited first, so the helper was stopped.
        case stoppedHelper
        /// The helper exited by itself; nothing was signalled.
        case helperExitedFirst
        /// The helper could not be identified or watched; nothing was signalled.
        case notWatching
    }

    /// Starts a tether for a helper the app just launched. The caller keeps
    /// the returned process so it is collected when it exits.
    static func attach(executable: URL, helperPID: Int32, helperPath: String) -> Process? {
        let tether = Process()
        tether.executableURL = executable
        tether.arguments = [flag, String(getpid()), String(helperPID), helperPath]
        tether.environment = [:]
        tether.standardInput = FileHandle.nullDevice
        tether.standardOutput = FileHandle.nullDevice
        tether.standardError = FileHandle.nullDevice
        return (try? tether.run()) == nil ? nil : tether
    }

    /// Runs the tether and exits, when this process was started as one.
    /// Returns at once in the app itself.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard arguments.count > 1, arguments[1] == flag else { return }
        guard arguments.count == 5,
              let appPID = Int32(arguments[2]),
              let helperPID = Int32(arguments[3]) else {
            exit(EX_USAGE)
        }
        // A signal sent to the app by name (`pkill MacRemote`) reaches this
        // process too. It has to outlive the app to do its job.
        for polite in [SIGTERM, SIGINT, SIGHUP] {
            signal(polite, SIG_IGN)
        }
        _ = watch(
            appPID: appPID,
            helperPID: helperPID,
            helperPath: arguments[4],
            // An app that died before this process could watch it has handed
            // its children to launchd.
            appIsStillRunning: { getppid() == appPID }
        )
        exit(EXIT_SUCCESS)
    }

    /// Waits until the app or the helper exits. If the app goes first, asks
    /// the helper to stop, and forces it after `grace` seconds.
    static func watch(
        appPID: Int32,
        helperPID: Int32,
        helperPath: String,
        grace: TimeInterval = 5,
        appIsStillRunning: () -> Bool = { true }
    ) -> Outcome {
        let queue = kqueue()
        guard queue >= 0 else { return .notWatching }
        defer { close(queue) }

        // Watching a process pins its ID: until its exit arrives here, the ID
        // cannot belong to anything else. So the path check below stays true
        // for as long as this function may signal the helper.
        guard watchForExit(of: helperPID, on: queue) == .watching,
              TunnelService.executablePath(ofProcess: helperPID) == helperPath else {
            return .notWatching
        }

        switch watchForExit(of: appPID, on: queue) {
        case .failed:
            return .notWatching
        case .alreadyGone:
            break
        case .watching:
            guard appIsStillRunning() else { break }
            let exited = nextExit(on: queue, timeout: nil)
            if exited == helperPID { return .helperExitedFirst }
            guard exited == appPID else { return .notWatching }
        }

        kill(helperPID, SIGTERM)
        if nextExit(on: queue, timeout: grace) != helperPID {
            kill(helperPID, SIGKILL)
        }
        return .stoppedHelper
    }

    private enum Registration { case watching, alreadyGone, failed }

    private static func watchForExit(of pid: Int32, on queue: Int32) -> Registration {
        var change = Darwin.kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        if kevent(queue, &change, 1, nil, 0, nil) == 0 { return .watching }
        return errno == ESRCH ? .alreadyGone : .failed
    }

    /// The ID of the next watched process to exit, or nil on timeout or error.
    private static func nextExit(on queue: Int32, timeout: TimeInterval?) -> Int32? {
        var event = Darwin.kevent()
        while true {
            let count: Int32
            if let timeout {
                var limit = timespec(tv_sec: Int(timeout), tv_nsec: Int((timeout - timeout.rounded(.down)) * 1_000_000_000))
                count = kevent(queue, nil, 0, &event, 1, &limit)
            } else {
                count = kevent(queue, nil, 0, &event, 1, nil)
            }
            if count > 0 { return Int32(event.ident) }
            if count == 0 || errno != EINTR { return nil }
        }
    }
}
