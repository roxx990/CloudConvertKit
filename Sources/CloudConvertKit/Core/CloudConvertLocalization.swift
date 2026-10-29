//  Every user-facing string the kit produces goes through one function, so an
//  app can localise (or re-word) all of them without forking the package.
//
//      CloudConvertLocalization.setProvider { key, english in
//          NSLocalizedString(key, tableName: "CloudConvertKit", value: english, comment: "")
//      }
//
//  Keys are stable (`"cloudconvert.error.notConnected"`); the English text is
//  the default. Strings with arguments use `%@` / `%d` placeholders, which the
//  provider's translation must keep in the same order.
//

import Foundation

public enum CloudConvertLocalization {

    /// `(key, defaultEnglishText) -> text to display`.
    public typealias Provider = @Sendable (_ key: String, _ defaultValue: String) -> String

    private static let provider = LockedValue<Provider?>(nil)

    /// Installs a provider for every user-facing string. Call once at launch.
    public static func setProvider(_ newProvider: Provider?) {
        provider.set(newProvider)
    }

    /// Resolves a key through the installed provider.
    public static func string(_ key: String, _ defaultValue: String) -> String {
        provider.get()?(key, defaultValue) ?? defaultValue
    }

    static func format(_ key: String, _ defaultValue: String, _ arguments: CVarArg...) -> String {
        String(format: string(key, defaultValue), locale: Locale.current, arguments: arguments)
    }
}

/// A value behind a lock, for the few globals the kit keeps.
final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); value = newValue; lock.unlock()
    }

    @discardableResult
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}
