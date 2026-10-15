//
//  PasteboardClient.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import Carbon.HIToolbox
import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore
import Sauce
import SwiftUI

private let pasteboardLogger = HexLog.pasteboard

@DependencyClient
struct PasteboardClient {
    var paste: @Sendable (String) async -> Void
    var copy: @Sendable (String) async -> Void
    var sendKeyboardCommand: @Sendable (KeyboardCommand) async -> Void
    var insertTextDirectly: @Sendable (String) async -> Void
}

extension PasteboardClient: DependencyKey {
    static var liveValue: Self {
        let live = PasteboardClientLive()
        return .init(
            paste: { text in
                await live.paste(text: text)
            },
            copy: { text in
                await live.copy(text: text)
            },
            sendKeyboardCommand: { command in
                await live.sendKeyboardCommand(command)
            },
            insertTextDirectly: { text in
                await live.insertTextDirectly(text)
            }
        )
    }
}

extension DependencyValues {
    var pasteboard: PasteboardClient {
        get { self[PasteboardClient.self] }
        set { self[PasteboardClient.self] = newValue }
    }
}

struct PasteboardClientLive {
    @Shared(.hexSettings) var hexSettings: HexSettings
    
    private struct PasteboardSnapshot {
        let items: [[String: Any]]
        
        init(pasteboard: NSPasteboard) {
            var saved: [[String: Any]] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var itemDict: [String: Any] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        itemDict[type.rawValue] = data
                    }
                }
                saved.append(itemDict)
            }
            self.items = saved
        }
        
        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()
            for itemDict in items {
                let item = NSPasteboardItem()
                for (type, data) in itemDict {
                    if let data = data as? Data {
                        item.setData(data, forType: NSPasteboard.PasteboardType(rawValue: type))
                    }
                }
                pasteboard.writeObjects([item])
            }
        }
    }

    @MainActor
    func paste(text: String) async {
        // When mirroring through the Screen Sharing client, always type:
        // clipboard sync across the relay can lag or miss entirely, while
        // plain keystrokes traverse it cleanly.
        if hexSettings.useClipboardPaste && !Self.isScreenSharingFrontmost() {
            await pasteWithClipboard(text)
        } else {
            await typeText(text)
        }
    }
    
    @MainActor
    func copy(text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    @MainActor
    func sendKeyboardCommand(_ command: KeyboardCommand) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // Convert modifiers to CGEventFlags and key codes for modifier keys
        var modifierKeyCodes: [CGKeyCode] = []
        var flags = CGEventFlags()
        
        for modifier in command.modifiers.sorted {
            switch modifier.kind {
            case .command:
                flags.insert(.maskCommand)
                modifierKeyCodes.append(55) // Left Cmd
            case .shift:
                flags.insert(.maskShift)
                modifierKeyCodes.append(56) // Left Shift
            case .option:
                flags.insert(.maskAlternate)
                modifierKeyCodes.append(58) // Left Option
            case .control:
                flags.insert(.maskControl)
                modifierKeyCodes.append(59) // Left Control
            case .fn:
                flags.insert(.maskSecondaryFn)
                // Fn key doesn't need explicit key down/up
            }
        }
        
        // Press modifiers down
        for keyCode in modifierKeyCodes {
            let modDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            modDown?.post(tap: .cghidEventTap)
        }
        
        // Press main key if present
        if let key = command.key {
            let keyCode = Sauce.shared.keyCode(for: key)
            
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            keyDown?.flags = flags
            keyDown?.post(tap: .cghidEventTap)
            
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            keyUp?.flags = flags
            keyUp?.post(tap: .cghidEventTap)
        }
        
        // Release modifiers in reverse order
        for keyCode in modifierKeyCodes.reversed() {
            let modUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            modUp?.post(tap: .cghidEventTap)
        }
        
        pasteboardLogger.debug("Sent keyboard command: \(command.displayName)")
    }
    /// Inserts text at the focused element without touching the pasteboard,
    /// using the configured `textInsertionEngine`.
    @MainActor
    func insertTextDirectly(_ text: String) async {
        await typeText(text)
    }

    @MainActor
    private func typeText(_ text: String) async {
        if resolvedEngine() == .keyCodes {
            Self.postKeyCodes(text)
            pasteboardLogger.debug("Typed \(text.count) chars as plain key codes.")
            return
        }
        switch hexSettings.textInsertionEngine {
        case .appleScript:
            simulateTypingWithAppleScript(text)
        default:
            if (try? Self.insertTextAtCursor(text)) != nil {
                pasteboardLogger.debug("Inserted text via accessibility (\(text.count) chars).")
                return
            }
            await postUnicodeText(text)
        }
    }

    /// Resolves `.auto`: when the Screen Sharing client (com.apple.ScreenSharing)
    /// is frontmost, keystrokes are relayed to the remote Mac — Unicode-payload
    /// events lose their payload there and AX inserts land on the client window
    /// itself, so plain key codes are the only reliable insert.
    private func resolvedEngine() -> TextInsertionEngine {
        switch hexSettings.textInsertionEngine {
        case .auto:
            return Self.isScreenSharingFrontmost() ? .keyCodes : .native
        case let other:
            return other
        }
    }

    private static func isScreenSharingFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.ScreenSharing"
    }

    /// Posts Unicode text as CGEvent keyboard packets (max 20 UTF-16 units per event)
    /// to the HID stream. Fallback for apps that don't expose AX text editing.
    @MainActor
    private func postUnicodeText(_ text: String) async {
        Self.postUnicodeStatic(text)
    }

    private static func postUnicodeStatic(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        var utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let end = min(index + 20, utf16.count)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            utf16.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                let count = end - index
                down?.keyboardSetUnicodeString(stringLength: count, unicodeString: base.advanced(by: index))
                up?.keyboardSetUnicodeString(stringLength: count, unicodeString: base.advanced(by: index))
            }
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            index = end
        }
        pasteboardLogger.debug("Posted \(utf16.count) UTF-16 units via CGEvent Unicode injection.")
    }

    /// Types text as ordinary hardware-like keystroke pairs (real virtual keys +
    /// modifiers) posted to the HID stream. Unlike Unicode-payload events (keycode 0),
    /// plain keystrokes survive the Apple Screen Sharing input relay, which drops the
    /// payload and degrades such events to their bare keycode (a lone "a"). Characters
    /// not on the US ANSI layout fall back to Unicode packets (best-effort).
    private static func postKeyCodes(_ text: String) {
        if isScreenSharingFrontmost() {
            postKeyCodesMirrored(text)
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        releaseStuckModifiers(source)
        var pendingUnicode = ""
        for scalar in text.unicodeScalars {
            if let (code, flags) = usKey(for: scalar) {
                if !pendingUnicode.isEmpty {
                    postUnicodeStatic(pendingUnicode)
                    pendingUnicode = ""
                }
                let needsShift = flags.contains(.maskShift)
                if needsShift {
                    postModifierDown(56, source: source)
                    usleep(20_000)
                }
                postKey(code, flags: flags, source: source)
                if needsShift {
                    usleep(20_000)
                    postModifierUp(56, source: source)
                    usleep(5_000)
                } else {
                    usleep(4_000)
                }
            } else {
                pendingUnicode.unicodeScalars.append(scalar)
            }
        }
        if !pendingUnicode.isEmpty {
            postUnicodeStatic(pendingUnicode)
        }
    }

    /// Screen Sharing relay variant: the relay drops shift held across a
    /// character (posted transitions coalesce and per-event flags appear to be
    /// ignored), but latching state does cross — the Option latch we had to
    /// clean earlier proves it. So capitals are driven through the Caps Lock
    /// key: toggle on, type the letter unshifted, toggle off as needed, and
    /// restore the user's original caps state at the end. Shift-only symbols
    /// (??? !!!) keep a long 50 ms physical-style shift hold.
    private static func postKeyCodesMirrored(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        releaseStuckModifiers(source)
        let capsWasOn = CGEventSource.keyState(.hidSystemState, key: 57)
        var capsOn = capsWasOn
        var pendingUnicode = ""

        func setCaps(_ on: Bool) {
            guard capsOn != on else { return }
            pressCapsLock(source)
            capsOn = on
            usleep(50_000)
        }

        for scalar in text.unicodeScalars {
            guard let (code, flags) = usKey(for: scalar) else {
                pendingUnicode.unicodeScalars.append(scalar)
                continue
            }
            if !pendingUnicode.isEmpty {
                postUnicodeStatic(pendingUnicode)
                pendingUnicode = ""
            }
            let isLetter = (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
            let needsShift = flags.contains(.maskShift)
            if isLetter {
                setCaps(needsShift)
                postKey(code, flags: [], source: source)
            } else if needsShift {
                postModifierDown(56, source: source)
                usleep(50_000)
                postKey(code, flags: [.maskShift], source: source)
                usleep(50_000)
                postModifierUp(56, source: source)
                usleep(10_000)
            } else {
                postKey(code, flags: [], source: source)
            }
            usleep(6_000)
        }
        if !pendingUnicode.isEmpty {
            postUnicodeStatic(pendingUnicode)
        }
        setCaps(capsWasOn)
    }

    private static func pressCapsLock(_ source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: false) else { return }
        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
    }

    /// Over Apple Screen Sharing the relayed Option from the hotkey press can
    /// stay latched while injection begins, mapping every character through the
    /// Option alternates ("Test" arrives as "†´ß†"). Explicitly release held
    /// modifiers first so keystrokes are clean.
    private static func releaseStuckModifiers(_ source: CGEventSource?) {
        let held = CGEventSource.flagsState(.combinedSessionState)
        var remaining = held
        var released = false
        for (mask, code) in [(CGEventFlags.maskShift, CGKeyCode(56)),
                              (.maskControl, 59),
                              (.maskAlternate, 58),
                              (.maskCommand, 55)] where held.contains(mask) {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { continue }
            remaining.remove(mask)
            ev.flags = remaining
            ev.post(tap: .cghidEventTap)
            usleep(500)
            released = true
        }
        if released {
            usleep(4_000)
        }
    }

    /// Shift is the only modifier typed mid-text; held across the character like
    /// hardware so relayed sessions translate it faithfully.
    private static func postModifierDown(_ code: CGKeyCode, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        down.flags = [.maskShift]
        down.post(tap: .cghidEventTap)
        usleep(500)
    }

    private static func postModifierUp(_ code: CGKeyCode, source: CGEventSource?) {
        guard let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        up.flags = []
        up.post(tap: .cghidEventTap)
        usleep(500)
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags, source: CGEventSource?) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// US ANSI virtual-key map. Non-US layouts map the ASCII basics identically;
    /// anything outside falls back to Unicode packets.
    private static func usKey(for scalar: UnicodeScalar) -> (CGKeyCode, CGEventFlags)? {
        let shift: CGEventFlags = .maskShift
        switch scalar {
        case "a": return (CGKeyCode(kVK_ANSI_A), [])
        case "b": return (CGKeyCode(kVK_ANSI_B), [])
        case "c": return (CGKeyCode(kVK_ANSI_C), [])
        case "d": return (CGKeyCode(kVK_ANSI_D), [])
        case "e": return (CGKeyCode(kVK_ANSI_E), [])
        case "f": return (CGKeyCode(kVK_ANSI_F), [])
        case "g": return (CGKeyCode(kVK_ANSI_G), [])
        case "h": return (CGKeyCode(kVK_ANSI_H), [])
        case "i": return (CGKeyCode(kVK_ANSI_I), [])
        case "j": return (CGKeyCode(kVK_ANSI_J), [])
        case "k": return (CGKeyCode(kVK_ANSI_K), [])
        case "l": return (CGKeyCode(kVK_ANSI_L), [])
        case "m": return (CGKeyCode(kVK_ANSI_M), [])
        case "n": return (CGKeyCode(kVK_ANSI_N), [])
        case "o": return (CGKeyCode(kVK_ANSI_O), [])
        case "p": return (CGKeyCode(kVK_ANSI_P), [])
        case "q": return (CGKeyCode(kVK_ANSI_Q), [])
        case "r": return (CGKeyCode(kVK_ANSI_R), [])
        case "s": return (CGKeyCode(kVK_ANSI_S), [])
        case "t": return (CGKeyCode(kVK_ANSI_T), [])
        case "u": return (CGKeyCode(kVK_ANSI_U), [])
        case "v": return (CGKeyCode(kVK_ANSI_V), [])
        case "w": return (CGKeyCode(kVK_ANSI_W), [])
        case "x": return (CGKeyCode(kVK_ANSI_X), [])
        case "y": return (CGKeyCode(kVK_ANSI_Y), [])
        case "z": return (CGKeyCode(kVK_ANSI_Z), [])
        case "0": return (CGKeyCode(kVK_ANSI_0), [])
        case "1": return (CGKeyCode(kVK_ANSI_1), [])
        case "2": return (CGKeyCode(kVK_ANSI_2), [])
        case "3": return (CGKeyCode(kVK_ANSI_3), [])
        case "4": return (CGKeyCode(kVK_ANSI_4), [])
        case "5": return (CGKeyCode(kVK_ANSI_5), [])
        case "6": return (CGKeyCode(kVK_ANSI_6), [])
        case "7": return (CGKeyCode(kVK_ANSI_7), [])
        case "8": return (CGKeyCode(kVK_ANSI_8), [])
        case "9": return (CGKeyCode(kVK_ANSI_9), [])
        case " ": return (CGKeyCode(kVK_Space), [])
        case "\n": return (CGKeyCode(kVK_Return), [])
        case "\t": return (CGKeyCode(kVK_Tab), [])
        case "-": return (CGKeyCode(kVK_ANSI_Minus), [])
        case "=": return (CGKeyCode(kVK_ANSI_Equal), [])
        case "[": return (CGKeyCode(kVK_ANSI_LeftBracket), [])
        case "]": return (CGKeyCode(kVK_ANSI_RightBracket), [])
        case "\\": return (CGKeyCode(kVK_ANSI_Backslash), [])
        case ";": return (CGKeyCode(kVK_ANSI_Semicolon), [])
        case "'": return (CGKeyCode(kVK_ANSI_Quote), [])
        case ",": return (CGKeyCode(kVK_ANSI_Comma), [])
        case ".": return (CGKeyCode(kVK_ANSI_Period), [])
        case "/": return (CGKeyCode(kVK_ANSI_Slash), [])
        case "`": return (CGKeyCode(kVK_ANSI_Grave), [])
        case "!": return (CGKeyCode(kVK_ANSI_1), shift)
        case "@": return (CGKeyCode(kVK_ANSI_2), shift)
        case "#": return (CGKeyCode(kVK_ANSI_3), shift)
        case "$": return (CGKeyCode(kVK_ANSI_4), shift)
        case "%": return (CGKeyCode(kVK_ANSI_5), shift)
        case "^": return (CGKeyCode(kVK_ANSI_6), shift)
        case "&": return (CGKeyCode(kVK_ANSI_7), shift)
        case "*": return (CGKeyCode(kVK_ANSI_8), shift)
        case "(": return (CGKeyCode(kVK_ANSI_9), shift)
        case ")": return (CGKeyCode(kVK_ANSI_0), shift)
        case "_": return (CGKeyCode(kVK_ANSI_Minus), shift)
        case "+": return (CGKeyCode(kVK_ANSI_Equal), shift)
        case "{": return (CGKeyCode(kVK_ANSI_LeftBracket), shift)
        case "}": return (CGKeyCode(kVK_ANSI_RightBracket), shift)
        case "|": return (CGKeyCode(kVK_ANSI_Backslash), shift)
        case ":": return (CGKeyCode(kVK_ANSI_Semicolon), shift)
        case "\"": return (CGKeyCode(kVK_ANSI_Quote), shift)
        case "<": return (CGKeyCode(kVK_ANSI_Comma), shift)
        case ">": return (CGKeyCode(kVK_ANSI_Period), shift)
        case "?": return (CGKeyCode(kVK_ANSI_Slash), shift)
        case "~": return (CGKeyCode(kVK_ANSI_Grave), shift)
        default:
            if scalar.value >= 65, scalar.value <= 90,
               let lower = UnicodeScalar(scalar.value + 32) {
                if let mapped = usKey(for: lower) {
                    return (mapped.0, shift)
                }
            }
            return nil
        }
    }

    /// Pastes current clipboard content to the frontmost application
    static func pasteToFrontmostApp() -> Bool {
        let script = """
        if application "System Events" is not running then
            tell application "System Events" to launch
            delay 0.1
        end if
        tell application "System Events"
            tell process (name of first application process whose frontmost is true)
                tell (menu item "Paste" of menu of menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        log (get properties of it)
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    end if
                end tell
                tell (menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1)
                    if exists then
                        if enabled then
                            click it
                            return true
                        else
                            return false
                        end if
                    else
                        return false
                    end if
                end tell
            end tell
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let result = scriptObject.executeAndReturnError(&error)
            if let error = error {
                pasteboardLogger.error("AppleScript paste failed: \(error)")
                return false
            }
            return result.booleanValue
        }
        return false
    }

    @MainActor
    func pasteWithClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let targetChangeCount = writeAndTrackChangeCount(pasteboard: pasteboard, text: text)
        _ = await waitForPasteboardCommit(targetChangeCount: targetChangeCount)
        let pasteSucceeded = await performPaste(text)
        
        // Only restore original pasteboard contents if:
        // 1. Copying to clipboard is disabled AND
        // 2. The paste operation succeeded
        if !hexSettings.copyToClipboard && pasteSucceeded {
            let savedSnapshot = snapshot
            Task { @MainActor in
                // Give slower apps a short window to read the plain-text entry
                // before we repopulate the clipboard with the user's previous rich data.
                try? await Task.sleep(for: .milliseconds(500))
                pasteboard.clearContents()
                savedSnapshot.restore(to: pasteboard)
            }
        }
        
        // If we failed to paste AND user doesn't want clipboard retention,
        // show a notification that text is available in clipboard
        if !pasteSucceeded && !hexSettings.copyToClipboard {
            // Keep the transcribed text in clipboard regardless of setting
            pasteboardLogger.notice("Paste operation failed; text remains in clipboard as fallback.")
            
            // TODO: Could add a notification here to inform user
            // that text is available in clipboard
        }
    }

    @MainActor
    private func writeAndTrackChangeCount(pasteboard: NSPasteboard, text: String) -> Int {
        let before = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let after = pasteboard.changeCount
        if after == before {
            // Ensure we always advance by at least one to avoid infinite waits if the system
            // coalesces writes (seen on Sonoma betas with zero-length strings).
            return after + 1
        }
        return after
    }

    @MainActor
    private func waitForPasteboardCommit(
        targetChangeCount: Int,
        timeout: Duration = .milliseconds(150),
        pollInterval: Duration = .milliseconds(5)
    ) async -> Bool {
        guard targetChangeCount > NSPasteboard.general.changeCount else { return true }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSPasteboard.general.changeCount >= targetChangeCount {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }

    // MARK: - Paste Orchestration

    @MainActor
    private enum PasteStrategy: CaseIterable {
        case cmdV
        case menuItem
        case accessibility
    }

    @MainActor
    private func performPaste(_ text: String) async -> Bool {
        for strategy in PasteStrategy.allCases {
            if await attemptPaste(text, using: strategy) {
                return true
            }
        }
        return false
    }

    @MainActor
    private func attemptPaste(_ text: String, using strategy: PasteStrategy) async -> Bool {
        switch strategy {
        case .cmdV:
            return await postCmdV(delayMs: 0)
        case .menuItem:
            return PasteboardClientLive.pasteToFrontmostApp()
        case .accessibility:
            return (try? Self.insertTextAtCursor(text)) != nil
        }
    }

    // MARK: - Helpers

    @MainActor
    private func postCmdV(delayMs: Int) async -> Bool {
        // Optional tiny wait before keystrokes
        try? await wait(milliseconds: delayMs)
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = vKeyCode()
        let cmdKey: CGKeyCode = 55
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false)
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
        return true
    }

    @MainActor
    private func vKeyCode() -> CGKeyCode {
        if Thread.isMainThread { return Sauce.shared.keyCode(for: .v) }
        return DispatchQueue.main.sync { Sauce.shared.keyCode(for: .v) }
    }

    @MainActor
    private func wait(milliseconds: Int) async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }
    
    func simulateTypingWithAppleScript(_ text: String) {
        let escapedText = text.replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"System Events\" to keystroke \"\(escapedText)\"")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error = error {
            pasteboardLogger.error("Error executing AppleScript typing fallback: \(error)")
        }
    }

    enum PasteError: Error {
        case systemWideElementCreationFailed
        case focusedElementNotFound
        case elementDoesNotSupportTextEditing
        case failedToInsertText
    }
    
    static func insertTextAtCursor(_ text: String) throws {
        // Get the system-wide accessibility element
        let systemWideElement = AXUIElementCreateSystemWide()
        
        // Get the focused element
        var focusedElementRef: CFTypeRef?
        let axError = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        
        guard axError == .success, let focusedElementRef = focusedElementRef else {
            throw PasteError.focusedElementNotFound
        }
        
        let focusedElement = focusedElementRef as! AXUIElement
        
        // Verify if the focused element supports text insertion
        var value: CFTypeRef?
        let supportsText = AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute as CFString, &value) == .success
        let supportsSelectedText = AXUIElementCopyAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, &value) == .success
        
        if !supportsText && !supportsSelectedText {
            throw PasteError.elementDoesNotSupportTextEditing
        }

        // Insert text at cursor position by replacing selected text (or empty selection)
        let insertResult = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        
        if insertResult != .success {
            throw PasteError.failedToInsertText
        }
    }
}
