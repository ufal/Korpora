import CorpusEngine
import Foundation

public enum PandoError: Error, CustomStringConvertible {
    case libraryUnavailable(String)
    case failure(String)
    /// The engine has no equivalent of this operation (see `EngineCapabilities`).
    case unsupported(String)

    public var description: String {
        switch self {
        case .libraryUnavailable(let reason): return "The pando library isn\u{2019}t available: \(reason)"
        case .failure(let message): return message
        case .unsupported(let what): return "\(what) isn\u{2019}t available for pando corpora."
        }
    }
}

/// `libpando` loaded at run time through its C API (`pando_ffi.h`), so the app
/// has no build-time dependency on pando and works without it. Like FQS, it
/// looks for the library in a few places and says what it checked.
public final class PandoLibrary: @unchecked Sendable {
    typealias OpenFn = @convention(c) (UnsafePointer<CChar>?, Int32) -> OpaquePointer?
    typealias LastErrorFn = @convention(c) () -> UnsafePointer<CChar>?
    typealias CancelFn = @convention(c) (OpaquePointer?) -> Void
    typealias CallFn = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    typealias InfoFn = @convention(c) (OpaquePointer?) -> UnsafeMutablePointer<CChar>?
    typealias FreeFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    typealias CloseFn = @convention(c) (OpaquePointer?) -> Void

    let open: OpenFn
    let lastError: LastErrorFn
    let cancel: CancelFn
    let query: CallFn
    let run: CallFn
    let info: InfoFn
    let free: FreeFn
    let close: CloseFn
    public let path: String

    private let image: UnsafeMutableRawPointer

    public init(path: String) throws {
        guard let image = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw PandoError.libraryUnavailable(String(cString: dlerror()))
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(image, name) else {
                throw PandoError.libraryUnavailable("\(path) lacks \(name) (an older pando?)")
            }
            return unsafeBitCast(address, to: type)
        }
        self.image = image
        self.path = path
        open = try symbol("pando_open", as: OpenFn.self)
        lastError = try symbol("pando_last_error", as: LastErrorFn.self)
        cancel = try symbol("pando_cancel", as: CancelFn.self)
        query = try symbol("pando_query", as: CallFn.self)
        run = try symbol("pando_run", as: CallFn.self)
        info = try symbol("pando_info", as: InfoFn.self)
        free = try symbol("pando_free_string", as: FreeFn.self)
        close = try symbol("pando_close", as: CloseFn.self)
    }

    /// Where a library is looked for, in order: `$KORPORA_PANDO_LIB`, next to
    /// the app executable, `/usr/local/lib`.
    public static func candidatePaths() -> [String] {
        var paths: [String] = []
        if let explicit = ProcessInfo.processInfo.environment["KORPORA_PANDO_LIB"], !explicit.isEmpty {
            return [explicit]
        }
        if let frameworks = Bundle.main.privateFrameworksPath { paths.append(frameworks + "/libpando.dylib") }
        paths.append("/usr/local/lib/libpando.dylib")
        return paths
    }

    /// The first library that loads, or an error listing what was tried.
    public static func find() throws -> PandoLibrary {
        var tried: [String] = []
        for path in candidatePaths() {
            do { return try PandoLibrary(path: path) } catch { tried.append("\(path): \(error)") }
        }
        throw PandoError.libraryUnavailable(tried.joined(separator: "; "))
    }

    // MARK: Calls

    func openHandle(directory: String) throws -> OpaquePointer {
        guard let handle = open(directory, 0) else {
            let reason = lastError().map { String(cString: $0) } ?? ""
            throw PandoError.failure(reason.isEmpty ? "Couldn\u{2019}t open the pando corpus at \(directory)." : reason)
        }
        return handle
    }

    /// Calls one of the JSON-returning functions and unwraps `{"ok": ...}`.
    func result(_ pointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let pointer else { throw PandoError.failure("pando returned nothing.") }
        defer { free(pointer) }
        let data = Data(bytes: pointer, count: strlen(pointer))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PandoError.failure("pando returned something other than a JSON object.")
        }
        if object["ok"] as? Bool == false {
            if object["cancelled"] as? Bool == true { throw CancellationError() }
            throw PandoError.failure(object["error"] as? String ?? "pando reported an error.")
        }
        return object["result"] as? [String: Any] ?? object
    }

    static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
