import ApplicationServices
import Foundation

/// App-level classification of `AXError`. Unsupported/missing attributes are normal and are
/// reported as `.unsupported`/`.noValue`, not as failures of the whole scan.
enum AXFailure: Error, Sendable, Hashable {
    case notTrusted
    case invalidElement
    /// The target did not answer in time or the connection is gone (`kAXErrorCannotComplete`).
    case notResponding
    case unsupported
    case noValue
    case other(Int32)

    init(_ error: AXError) {
        switch error {
        case .apiDisabled: self = .notTrusted
        case .invalidUIElement: self = .invalidElement
        case .cannotComplete: self = .notResponding
        case .attributeUnsupported, .actionUnsupported, .notImplemented,
             .parameterizedAttributeUnsupported, .notificationUnsupported:
            self = .unsupported
        case .noValue: self = .noValue
        default: self = .other(error.rawValue)
        }
    }

    /// Whether the failure means "the element is dead", as opposed to "try again later".
    var indicatesDeadElement: Bool { self == .invalidElement }
}

/// Typed attribute access on `AXUIElement`. All calls happen on the AX actor.
@AXActor
enum AXElement {
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> Result<CFTypeRef?, AXFailure> {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return .failure(AXFailure(error)) }
        return .success(value)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> Result<String?, AXFailure> {
        copyAttribute(element, attribute).map { $0 as? String }
    }

    static func bool(_ element: AXUIElement, _ attribute: String) -> Result<Bool?, AXFailure> {
        copyAttribute(element, attribute).map { value in
            guard let value else { return nil }
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return CFBooleanGetValue((value as! CFBoolean))
            }
            return (value as? NSNumber)?.boolValue
        }
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> Result<AXUIElement?, AXFailure> {
        copyAttribute(element, attribute).map { value in
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    static func elements(_ element: AXUIElement, _ attribute: String) -> Result<[AXUIElement], AXFailure> {
        copyAttribute(element, attribute).map { value in
            guard let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
            let array = value as! CFArray
            let count = CFArrayGetCount(array)
            var result: [AXUIElement] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(array, index) else { continue }
                let item = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
                if CFGetTypeID(item) == AXUIElementGetTypeID() {
                    result.append(item as! AXUIElement)
                }
            }
            return result
        }
    }

    /// Reads several attributes with a single round trip. Unsupported or missing attributes
    /// come back as `nil` entries; only element-level failures (dead element, timeout, no
    /// permission) fail the whole call.
    static func copyAttributes(_ element: AXUIElement, _ attributes: [String]) -> Result<[CFTypeRef?], AXFailure> {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success, let values else { return .failure(AXFailure(error)) }
        let count = CFArrayGetCount(values)
        var result: [CFTypeRef?] = Array(repeating: nil, count: attributes.count)
        for index in 0..<min(count, attributes.count) {
            guard let raw = CFArrayGetValueAtIndex(values, index) else { continue }
            let item = Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType((item as! AXValue)) == .axError {
                var code = AXError.success
                AXValueGetValue((item as! AXValue), .axError, &code)
                let failure = AXFailure(code)
                if failure == .invalidElement || failure == .notResponding || failure == .notTrusted {
                    return .failure(failure)
                }
                continue
            }
            result[index] = item
        }
        return .success(result)
    }

    static func stringValue(_ value: CFTypeRef?) -> String? {
        value as? String
    }

    static func boolValue(_ value: CFTypeRef?) -> Bool? {
        guard let value else { return nil }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return CFBooleanGetValue((value as! CFBoolean))
        }
        return (value as? NSNumber)?.boolValue
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) -> Result<Void, AXFailure> {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
        return error == .success ? .success(()) : .failure(AXFailure(error))
    }

    static func setElement(_ element: AXUIElement, _ attribute: String, _ value: AXUIElement) -> Result<Void, AXFailure> {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        return error == .success ? .success(()) : .failure(AXFailure(error))
    }

    static func perform(_ element: AXUIElement, _ action: String) -> Result<Void, AXFailure> {
        let error = AXUIElementPerformAction(element, action as CFString)
        return error == .success ? .success(()) : .failure(AXFailure(error))
    }

    static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    static func setTimeout(_ element: AXUIElement, seconds: Float) {
        _ = AXUIElementSetMessagingTimeout(element, seconds)
    }

    static func isSame(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs)
    }
}
