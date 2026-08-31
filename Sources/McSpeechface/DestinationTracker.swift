import AppKit
import ApplicationServices
import Carbon
import McSpeechfaceEditing

struct ApplicationIdentity {
    let bundleIdentifier: String?
    let applicationName: String?

    func transcriptEditingContext(
        browserContext: TranscriptEditingDestinationContext? = nil
    ) -> TranscriptEditingDestinationContext {
        TranscriptEditingDestinationContext(
            applicationName: applicationName,
            applicationBundleIdentifier: bundleIdentifier,
            browserHost: browserContext?.browserHost,
            browserURL: browserContext?.browserURL
        )
    }
}

struct DestinationCapture {
    let session: DestinationSession?
    let identity: ApplicationIdentity?
    let browserLookup: BrowserDestinationContextLookup?
}

// AXUIElement is a retained Core Foundation reference and each lookup is timeout-bounded.
struct BrowserDestinationContextLookup: @unchecked Sendable {
    let focusedElement: AXUIElement?
    let windowElement: AXUIElement?
    let applicationElement: AXUIElement

    func resolve(includeFullURL: Bool) -> TranscriptEditingDestinationContext? {
        var element = focusedElement
        for _ in 0..<12 {
            guard !Task.isCancelled, let current = element else { break }
            AXUIElementSetMessagingTimeout(current, 0.05)
            let context = TranscriptEditingDestinationContext(
                browserURL: stringAttribute(kAXDocumentAttribute as CFString, of: current)
            )
            if context.browserHost != nil {
                return includeFullURL
                    ? context
                    : TranscriptEditingDestinationContext(browserHost: context.browserHost)
            }
            let parent = elementAttribute(kAXParentAttribute as CFString, of: current)
            if let parent, CFEqual(parent, current) { break }
            element = parent
        }
        for candidate in [windowElement, Optional(applicationElement)].compactMap({ $0 }) {
            guard !Task.isCancelled else { return nil }
            AXUIElementSetMessagingTimeout(candidate, 0.05)
            let context = TranscriptEditingDestinationContext(
                browserURL: stringAttribute(kAXDocumentAttribute as CFString, of: candidate)
            )
            if context.browserHost != nil {
                return includeFullURL
                    ? context
                    : TranscriptEditingDestinationContext(browserHost: context.browserHost)
            }
        }
        return nil
    }
}

struct PasteObservation: Sendable {
    let expectedValue: String?
    let expectedCharacterCount: Int?

    var canConfirmConsumption: Bool {
        expectedValue != nil || expectedCharacterCount != nil
    }
}

@MainActor
protocol PasteDestination {
    var isAvailable: Bool { get }
    var isSecure: Bool { get }
    var isFrontmost: Bool { get }
    var isFocused: Bool { get }
    var isCurrentPasteTargetAtDispatch: Bool { get }

    func restore() async -> Bool
    func observePasteTarget(afterInserting text: String) -> PasteObservation
    func hasConsumedPaste(since observation: PasteObservation) async -> Bool
}

@MainActor
struct DestinationSession: PasteDestination {
    private let application: NSRunningApplication
    private let applicationElement: AXUIElement
    private let windowElement: AXUIElement
    private let focusedElement: AXUIElement?

    var processIdentifier: pid_t { application.processIdentifier }
    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }
    var isCurrentPasteTargetAtDispatch: Bool {
        guard isFrontmost,
              let currentWindow = currentFocusedWindow(
                  for: applicationElement,
                  focusedElement: nil
              ) else { return false }
        guard CFEqual(currentWindow, windowElement) else { return false }
        guard let focusedElement else {
            return currentFocusedElement(
                for: applicationElement,
                processIdentifier: processIdentifier
            ) == nil
        }
        guard let currentElement = currentFocusedElement(
            for: applicationElement,
            processIdentifier: processIdentifier
        ) else { return false }
        return CFEqual(currentElement, focusedElement)
    }
    init(
        application: NSRunningApplication,
        applicationElement: AXUIElement,
        windowElement: AXUIElement,
        focusedElement: AXUIElement?
    ) {
        self.application = application
        self.applicationElement = applicationElement
        self.windowElement = windowElement
        self.focusedElement = focusedElement
    }

    var isAvailable: Bool {
        guard !application.isTerminated,
              NSRunningApplication(processIdentifier: processIdentifier) != nil,
              belongsToApplication(windowElement),
              focusedElement.map(belongsToApplication) ?? true else { return false }

        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            focusedElement ?? windowElement,
            kAXRoleAttribute as CFString,
            &role
        ) == .success
    }

    var isSecure: Bool {
        if IsSecureEventInputEnabled() { return true }
        var element = focusedElement

        for _ in 0..<12 {
            guard let current = element else { return false }
            if stringAttribute(kAXSubroleAttribute as CFString, of: current) == kAXSecureTextFieldSubrole
                || boolAttribute(NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString, of: current) {
                return true
            }
            element = elementAttribute(kAXParentAttribute as CFString, of: current)
        }

        return false
    }

    func restore() async -> Bool {
        guard isAvailable else { return false }
        if isFrontmost, isFocused {
            return true
        }
        guard application.activate(options: []) else { return false }

        for _ in 0..<15 {
            guard isAvailable else { return false }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if frontmostPID == processIdentifier {
                if isFocused { return true }
                _ = AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFocusedWindowAttribute as CFString,
                    windowElement
                )
                _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
                guard let focusedElement else {
                    if isFocused { return true }
                    continue
                }
                let focusedViaApplication = AXUIElementSetAttributeValue(
                    applicationElement,
                    kAXFocusedUIElementAttribute as CFString,
                    focusedElement
                )
                let focusedDirectly = AXUIElementSetAttributeValue(
                    focusedElement,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
                if (focusedViaApplication == .success || focusedDirectly == .success)
                    && isFocused {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func observePasteTarget(afterInserting text: String) -> PasteObservation {
        guard let focusedElement,
              let range = rangeAttribute(kAXSelectedTextRangeAttribute as CFString, of: focusedElement),
              range.location >= 0,
              range.length >= 0 else {
            return PasteObservation(expectedValue: nil, expectedCharacterCount: nil)
        }

        let original = stringAttribute(kAXValueAttribute as CFString, of: focusedElement)
        let originalLength = original.map { ($0 as NSString).length }
            ?? integerAttribute(kAXNumberOfCharactersAttribute as CFString, of: focusedElement)
        guard let originalLength,
              originalLength <= 250_000,
              range.location <= originalLength,
              range.length <= originalLength - range.location else {
            return PasteObservation(expectedValue: nil, expectedCharacterCount: nil)
        }

        let expectedCharacterCount = originalLength - range.length + (text as NSString).length
        guard let original else {
            return PasteObservation(
                expectedValue: nil,
                expectedCharacterCount: expectedCharacterCount
            )
        }

        let expected = NSMutableString(string: original)
        expected.replaceCharacters(
            in: NSRange(location: range.location, length: range.length),
            with: text
        )
        let expectedValue = expected as String
        return PasteObservation(
            expectedValue: expectedValue == original ? nil : expectedValue,
            expectedCharacterCount: expectedCharacterCount == originalLength
                ? nil
                : expectedCharacterCount
        )
    }

    func hasConsumedPaste(since observation: PasteObservation) async -> Bool {
        guard let focusedElement else { return false }
        let target = SendablePasteTarget(
            applicationElement: applicationElement,
            windowElement: windowElement,
            focusedElement: focusedElement,
            processIdentifier: processIdentifier
        )
        return await Task.detached(priority: .utility) {
            target.applyMessagingTimeout()
            if let expectedValue = observation.expectedValue {
                return stringAttribute(
                    kAXValueAttribute as CFString,
                    of: target.focusedElement
                ) == expectedValue
            }
            if let expectedCharacterCount = observation.expectedCharacterCount {
                guard target.isFrontmost, target.isFocused else { return false }
                return integerAttribute(
                    kAXNumberOfCharactersAttribute as CFString,
                    of: target.focusedElement
                ) == expectedCharacterCount
            }
            return false
        }.value
    }

    var isFocused: Bool {
        guard let currentWindow = currentFocusedWindow(
                  for: applicationElement,
                  focusedElement: nil
              )
        else { return false }
        guard CFEqual(currentWindow, windowElement) else { return false }
        guard let focusedElement else {
            return currentFocusedElement(
                for: applicationElement,
                processIdentifier: processIdentifier
            ) == nil
        }
        guard let currentElement = currentFocusedElement(
            for: applicationElement,
            processIdentifier: processIdentifier
        ) else { return false }
        return CFEqual(currentElement, focusedElement)
    }

    private func belongsToApplication(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == processIdentifier
    }
}

@MainActor
final class DestinationTracker: NSObject {
    private var lastNonMcSpeechfaceApplication: NSRunningApplication?

    override init() {
        super.init()
        rememberIfEligible(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func capture(allowMcSpeechface: Bool = false) -> DestinationSession? {
        captureContext(allowMcSpeechface: allowMcSpeechface).session
    }

    func captureContext(
        allowMcSpeechface: Bool = false,
        includeIdentity: Bool = false,
        includeBrowserContext: Bool = false
    ) -> DestinationCapture {
        guard let application = currentApplication(allowMcSpeechface: allowMcSpeechface) else {
            return DestinationCapture(session: nil, identity: nil, browserLookup: nil)
        }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.05)
        let focusedElement = currentFocusedElement(
            for: applicationElement,
            processIdentifier: application.processIdentifier
        )
        let focusedWindow = currentFocusedWindow(
            for: applicationElement,
            focusedElement: focusedElement
        )
        // Some Electron editors expose their focused window but not the focused child.
        let session = focusedWindow.map {
            DestinationSession(
                application: application,
                applicationElement: applicationElement,
                windowElement: $0,
                focusedElement: focusedElement
            )
        }
        let identity = includeIdentity ? ApplicationIdentity(
            bundleIdentifier: application.bundleIdentifier,
            applicationName: application.localizedName
        ) : nil
        let browserLookup = includeIdentity && includeBrowserContext
            ? BrowserDestinationContextLookup(
                focusedElement: focusedElement,
                windowElement: focusedWindow,
                applicationElement: applicationElement
            )
            : nil
        return DestinationCapture(
            session: session,
            identity: identity,
            browserLookup: browserLookup
        )
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        rememberIfEligible(
            notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        )
    }

    private func rememberIfEligible(_ application: NSRunningApplication?) {
        guard let application,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else { return }
        lastNonMcSpeechfaceApplication = application
    }

    private func currentApplication(allowMcSpeechface: Bool) -> NSRunningApplication? {
        rememberIfEligible(NSWorkspace.shared.frontmostApplication)
        if allowMcSpeechface,
           let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return frontmost
        }
        guard let application = lastNonMcSpeechfaceApplication,
              !application.isTerminated else { return nil }
        return application
    }
}

// AXUIElement is a retained Core Foundation reference; each off-main call is bounded below.
private struct SendablePasteTarget: @unchecked Sendable {
    let applicationElement: AXUIElement
    let windowElement: AXUIElement
    let focusedElement: AXUIElement
    let processIdentifier: pid_t

    func applyMessagingTimeout() {
        AXUIElementSetMessagingTimeout(applicationElement, 0.05)
        AXUIElementSetMessagingTimeout(windowElement, 0.05)
        AXUIElementSetMessagingTimeout(focusedElement, 0.05)
    }

    var isFrontmost: Bool {
        boolAttribute(kAXFrontmostAttribute as CFString, of: applicationElement)
    }

    var isFocused: Bool {
        guard let currentWindow = currentFocusedWindow(
            for: applicationElement,
            focusedElement: nil
        ), CFEqual(currentWindow, windowElement) else { return false }
        guard let currentElement = currentFocusedElement(
            for: applicationElement,
            processIdentifier: processIdentifier
        ) else { return false }
        return CFEqual(currentElement, focusedElement)
    }
}

private func elementAttribute(_ attribute: CFString, of element: AXUIElement) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
          let value,
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}

private func currentFocusedElement(
    for applicationElement: AXUIElement,
    processIdentifier: pid_t
) -> AXUIElement? {
    if let focused = elementAttribute(
        kAXFocusedUIElementAttribute as CFString,
        of: applicationElement
    ) {
        return focused
    }

    let systemWide = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(systemWide, 0.05)
    guard let focused = elementAttribute(
        kAXFocusedUIElementAttribute as CFString,
        of: systemWide
    ) else { return nil }
    var focusedPID: pid_t = 0
    guard AXUIElementGetPid(focused, &focusedPID) == .success,
          focusedPID == processIdentifier else { return nil }
    return focused
}

private func currentFocusedWindow(
    for applicationElement: AXUIElement,
    focusedElement: AXUIElement?
) -> AXUIElement? {
    if let window = elementAttribute(
        kAXFocusedWindowAttribute as CFString,
        of: applicationElement
    ) {
        return window
    }
    guard let focusedElement else { return nil }
    AXUIElementSetMessagingTimeout(focusedElement, 0.05)
    return elementAttribute(kAXWindowAttribute as CFString, of: focusedElement)
}

private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

private func integerAttribute(_ attribute: CFString, of element: AXUIElement) -> Int? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return (value as? NSNumber)?.intValue
}

private func rangeAttribute(_ name: CFString, of element: AXUIElement) -> CFRange? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success,
          let value,
          CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let axValue = unsafeBitCast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cfRange else { return nil }
    var range = CFRange()
    return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
}

private func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return false }
    return (value as? NSNumber)?.boolValue == true
}
