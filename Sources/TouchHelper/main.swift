import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

@main
struct TouchHelperMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        static let panelSize = NSSize(width: 290, height: 78)
        static let keyboardSize = NSSize(width: 1_080, height: 320)
        static let minimumKeyboardSize = NSSize(width: 780, height: 320)
        static let keyboardSizeDefaultsKey = "keyboardSize"
        static let panelInset: CGFloat = 14
    }

    private var panel: TouchPanel!
    private var keyboardPanel: KeyboardPanel!
    private weak var closeButton: TrafficLightButton?
    private weak var minimizeButton: TrafficLightButton?
    private weak var zoomButton: TrafficLightButton?
    private var currentTarget: WindowTarget?
    private var keyboardTarget: WindowTarget?
    private var preferredKeyboardSize = Constants.keyboardSize
    private weak var touchKeyboard: TouchKeyboardView?
    private var inputSyncTimer: Timer?
    private var windowControlsRefreshTimer: Timer?
    private var observesKeyboardInputSource = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerForLaunchAtLogin()
        // The helper stays out of the Dock; it has its own always-ready panel.
        preferredKeyboardSize = restoredKeyboardSize()
        panel = makePanel()
        keyboardPanel = makeKeyboardPanel()
        observeActiveApplication()
        observeKeyboardInputSource()
        refreshTarget()
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopObservingKeyboardInputSource()
    }

    private func registerForLaunchAtLogin() {
        let launchService = SMAppService.mainApp
        guard launchService.status != .enabled else { return }

        do {
            try launchService.register()
        } catch {
            NSLog("TouchHelper could not register for launch at login: %@", error.localizedDescription)
        }

        if launchService.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        positionPanel()
    }

    // MARK: - Panel

    private func makePanel() -> TouchPanel {
        let panel = TouchPanel(
            contentRect: NSRect(origin: .zero, size: Constants.panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = makeContentView()
        position(panel)
        return panel
    }

    private func makeContentView() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        // Keep a consistently dark keyboard surface. With behind-window
        // blending, light content beneath the panel washed out the keys.
        effect.blendingMode = .withinWindow
        effect.appearance = NSAppearance(named: .darkAqua)
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 28
        effect.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let close = TrafficLightButton(color: .systemRed, symbol: "xmark", label: "Zavřít aktivní okno", diameter: 60)
        close.target = self
        close.action = #selector(closeWindow)
        closeButton = close

        let minimize = TrafficLightButton(color: .systemYellow, symbol: "minus", label: "Minimalizovat aktivní okno", diameter: 60)
        minimize.target = self
        minimize.action = #selector(minimizeWindow)
        minimizeButton = minimize

        let zoom = LongPressTrafficLightButton(
            color: .systemGreen,
            symbol: "arrow.up.left.and.arrow.down.right",
            label: "Zvětšit nebo obnovit aktivní okno",
            diameter: 60
        )
        zoom.target = self
        zoom.action = #selector(zoomWindow)
        zoom.onLongPress = { [weak self] _ in self?.showNativeZoomMenu() }
        zoomButton = zoom

        let keyboard = TrafficLightButton(
            color: NSColor.white.withAlphaComponent(0.18),
            symbol: "keyboard",
            label: "Zobrazit klávesnici",
            diameter: 60
        )
        keyboard.target = self
        keyboard.action = #selector(toggleKeyboard)

        [close, minimize, zoom, keyboard].forEach(stack.addArrangedSubview)
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])
        return effect
    }

    private func makeKeyboardPanel() -> KeyboardPanel {
        let panel = KeyboardPanel(
            contentRect: NSRect(origin: .zero, size: preferredKeyboardSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // `canJoinAllApplications` is the overlay behavior macOS uses for a
        // window that must also appear in another app's full-screen space.
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        // `isFloatingPanel` resets the window level. Set the final level only
        // afterwards, otherwise it silently drops back below app modals.
        // A few pro-audio applications render modal overlays above the normal
        // assistive-tech level, so use the highest application level directly
        // below macOS shielding windows.
        panel.level = NSWindow.Level(
            rawValue: Int(CGShieldingWindowLevel()) - 1
        )
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.minSize = Constants.minimumKeyboardSize
        panel.contentView = makeKeyboardContentView()
        return panel
    }

    private func makeKeyboardContentView() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 22
        effect.layer?.masksToBounds = true

        // Material alone remains too transparent over white web pages. This
        // dimming layer makes the key labels and their borders readable on
        // every underlying app while preserving a little of the glass effect.
        let dimmingLayer = NSView()
        dimmingLayer.wantsLayer = true
        dimmingLayer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        dimmingLayer.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(dimmingLayer)

        let keyboard = TouchKeyboardView()
        touchKeyboard = keyboard
        keyboard.onKeyPress = { [weak self] output in
            self?.sendKeyboardOutput(output)
        }
        keyboard.onHideKeyboard = { [weak self] in
            self?.hideKeyboard()
        }
        let preview = NSTextField(labelWithString: "Psaný text se ukáže tady")
        preview.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingHead
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        keyboard.onTextChanged = { text in
            preview.stringValue = text.isEmpty ? "Psaný text se ukáže tady" : text
            preview.textColor = text.isEmpty ? .secondaryLabelColor : .labelColor
        }
        keyboard.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(keyboard)
        effect.addSubview(preview)

        let resizeHandle = KeyboardResizeHandle()
        resizeHandle.onResize = { [weak self] size in
            self?.saveKeyboardSize(size)
        }
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(resizeHandle)
        NSLayoutConstraint.activate([
            dimmingLayer.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            dimmingLayer.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            dimmingLayer.topAnchor.constraint(equalTo: effect.topAnchor),
            dimmingLayer.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            keyboard.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            keyboard.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
            keyboard.topAnchor.constraint(equalTo: effect.topAnchor, constant: 42),
            keyboard.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -14),
            resizeHandle.topAnchor.constraint(equalTo: effect.topAnchor, constant: 8),
            resizeHandle.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
            resizeHandle.widthAnchor.constraint(equalToConstant: 25),
            resizeHandle.heightAnchor.constraint(equalToConstant: 25),
            preview.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            preview.trailingAnchor.constraint(equalTo: resizeHandle.leadingAnchor, constant: -10),
            preview.centerYAnchor.constraint(equalTo: resizeHandle.centerYAnchor),
            preview.heightAnchor.constraint(equalToConstant: 25)
        ])
        return effect
    }

    private func positionPanel() {
        position(panel)
        if keyboardPanel.isVisible {
            positionKeyboard(keyboardPanel)
        }
    }

    private func position(_ panel: NSPanel) {
        // visibleFrame tells us whether the Dock is currently reserving the bottom edge.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let bottomDockHeight = max(0, visibleFrame.minY - screen.frame.minY)
        let point: NSPoint
        if bottomDockHeight > 0 {
            // A bottom Dock reserves this part of the display. Center the helper
            // vertically within it so both controls share the same baseline.
            point = NSPoint(
                x: screen.frame.minX + Constants.panelInset,
                y: screen.frame.minY + max(0, (bottomDockHeight - Constants.panelSize.height) / 2)
            )
        } else {
            point = NSPoint(
                x: visibleFrame.minX + Constants.panelInset,
                y: visibleFrame.minY + Constants.panelInset
            )
        }
        panel.setFrameOrigin(point)
    }

    private func keyboardFrame(on screen: NSScreen) -> NSRect {
        let size = constrainedKeyboardSize(preferredKeyboardSize, on: screen)
        let width = size.width
        let height = size.height
        return NSRect(
            x: screen.visibleFrame.midX - width / 2,
            y: screen.visibleFrame.minY + Constants.panelInset,
            width: width,
            height: height
        )
    }

    private func positionKeyboard(_ keyboard: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        keyboard.setFrame(keyboardFrame(on: screen), display: true)
    }

    private func restoredKeyboardSize() -> NSSize {
        guard let stored = UserDefaults.standard.dictionary(forKey: Constants.keyboardSizeDefaultsKey),
              let width = stored["width"] as? NSNumber,
              let height = stored["height"] as? NSNumber else { return Constants.keyboardSize }
        return NSSize(width: width.doubleValue, height: height.doubleValue)
    }

    private func constrainedKeyboardSize(_ size: NSSize, on screen: NSScreen) -> NSSize {
        let maximum = NSSize(
            width: screen.visibleFrame.width - Constants.panelInset * 2,
            height: screen.visibleFrame.height - Constants.panelInset * 2
        )
        return NSSize(
            width: min(maximum.width, max(Constants.minimumKeyboardSize.width, size.width)),
            height: min(maximum.height, max(Constants.minimumKeyboardSize.height, size.height))
        )
    }

    private func saveKeyboardSize(_ size: NSSize) {
        preferredKeyboardSize = size
        UserDefaults.standard.set(["width": size.width, "height": size.height], forKey: Constants.keyboardSizeDefaultsKey)
    }

    // MARK: - Target window

    private func observeActiveApplication() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func activeApplicationChanged(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        currentTarget = WindowTarget(pid: application.processIdentifier)
        touchKeyboard?.reloadKeyboardLayout()
        updateWindowControlsAvailability()
    }

    private func observeKeyboardInputSource() {
        guard !observesKeyboardInputSource else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            keyboardInputSourceChanged,
            kTISNotifySelectedKeyboardInputSourceChanged,
            nil,
            .deliverImmediately
        )
        observesKeyboardInputSource = true
    }

    private func stopObservingKeyboardInputSource() {
        guard observesKeyboardInputSource else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDistributedCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged),
            nil
        )
        observesKeyboardInputSource = false
    }

    fileprivate func keyboardInputSourceDidChange() {
        touchKeyboard?.reloadKeyboardLayout()
    }

    private func refreshTarget() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        currentTarget = WindowTarget(pid: application.processIdentifier)
    }

    private func updateWindowControlsAvailability() {
        // Keep the buttons usable while macOS is still asking for permission.
        // Once access is granted, gray out only controls that the focused window
        // does not expose through Accessibility instead of interrupting the user
        // with a modal warning.
        guard AXIsProcessTrusted(), let target = currentTarget else {
            stopWindowControlsRefresh()
            setWindowControlsEnabled(true)
            return
        }

        // Immediately after minimizing a window, macOS removes its
        // AXFocusedWindow before the Dock has finished restoring it. Brave
        // does not always emit another application-activation notification on
        // restore, so retry until its focused window is published again.
        guard target.hasFocusedWindow() else {
            setWindowControlsEnabled(false)
            startWindowControlsRefresh()
            return
        }

        let closeSupported = target.supports(.close)
        let minimizeSupported = target.supports(.minimize)
        let zoomSupported = target.supports(.zoom)
        closeButton?.isEnabled = closeSupported
        minimizeButton?.isEnabled = minimizeSupported
        zoomButton?.isEnabled = zoomSupported

        if closeSupported || minimizeSupported || zoomSupported {
            stopWindowControlsRefresh()
        } else {
            startWindowControlsRefresh()
        }
    }

    private func startWindowControlsRefresh() {
        guard windowControlsRefreshTimer == nil else { return }

        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTarget()
                self?.updateWindowControlsAvailability()
            }
        }
        windowControlsRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopWindowControlsRefresh() {
        windowControlsRefreshTimer?.invalidate()
        windowControlsRefreshTimer = nil
    }

    private func setWindowControlsEnabled(_ isEnabled: Bool) {
        closeButton?.isEnabled = isEnabled
        minimizeButton?.isEnabled = isEnabled
        zoomButton?.isEnabled = isEnabled
    }

    private func perform(_ action: WindowAction) {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            return
        }
        refreshTarget()
        guard let target = currentTarget, target.supports(action) else {
            updateWindowControlsAvailability()
            return
        }
        _ = target.perform(action)
        updateWindowControlsAvailability()
        if action == .minimize {
            refreshWindowControlsAfterMinimize()
        }
    }

    private func refreshWindowControlsAfterMinimize() {
        // `AXFocusedWindow` may still describe the old window while the
        // minimize animation is running. Query again once that transition has
        // completed; if Brave has not published a usable window yet, the
        // refresh timer takes over until it does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshTarget()
            self?.updateWindowControlsAvailability()
        }
    }

    @objc private func closeWindow() { perform(.close) }
    @objc private func minimizeWindow() { perform(.minimize) }
    @objc private func zoomWindow() { perform(.zoom) }

    @objc private func toggleKeyboard() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            return
        }

        if keyboardPanel.isVisible {
            hideKeyboard()
            return
        }

        refreshTarget()
        guard let target = currentTarget else {
            return
        }
        keyboardTarget = target
        showKeyboard()
    }

    private func showKeyboard() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        touchKeyboard?.reloadKeyboardLayout()
        let finalFrame = keyboardFrame(on: screen)
        let hiddenFrame = finalFrame.offsetBy(dx: 0, dy: -finalFrame.height - Constants.panelInset)
        keyboardPanel.setFrame(hiddenFrame, display: false)
        keyboardPanel.alphaValue = 0
        keyboardPanel.orderFrontRegardless()
        syncPreviewWithFocusedInput()
        startInputSync()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            keyboardPanel.animator().setFrame(finalFrame, display: true)
            keyboardPanel.animator().alphaValue = 1
        }
    }

    private func hideKeyboard() {
        stopInputSync()
        let hiddenFrame = keyboardPanel.frame.offsetBy(dx: 0, dy: -keyboardPanel.frame.height - Constants.panelInset)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            keyboardPanel.animator().setFrame(hiddenFrame, display: true)
            keyboardPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.keyboardPanel.orderOut(nil)
                self?.keyboardPanel.alphaValue = 1
            }
        }
    }

    private func sendKeyboardOutput(_ output: KeyboardOutput) {
        guard let target = keyboardTarget else { return }
        target.send(output)
    }

    private func startInputSync() {
        stopInputSync()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Aurora and similar applications can re-order their modal
                // panels while they remain open. Reassert this non-activating
                // panel's position without stealing focus from the target app.
                self?.keyboardPanel.orderFrontRegardless()
                self?.syncPreviewWithFocusedInput()
            }
        }
        inputSyncTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopInputSync() {
        inputSyncTimer?.invalidate()
        inputSyncTimer = nil
    }

    private func syncPreviewWithFocusedInput() {
        guard let target = keyboardTarget else { return }
        // AXValue is exposed by standard text fields and text views. An empty
        // value is meaningful too: it tells us that Tab reached a blank field.
        touchKeyboard?.replacePreviewText(target.focusedText() ?? "")
    }

    private func showNativeZoomMenu() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            return
        }
        refreshTarget()
        // Some system dialogs and custom app windows do not expose a native
        // green-button menu. Treat that as a harmless no-op instead of showing
        // an alert over the window the user is trying to control.
        guard let target = currentTarget else { return }
        _ = target.showZoomMenu()
    }

    @objc private func requestAccessibilityPermission() {
        // The Accessibility framework exposes this as a mutable imported global in
        // recent Swift SDKs. Its documented string value avoids that concurrency
        // warning while preserving the normal macOS permission prompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

}

private let keyboardInputSourceChanged: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            delegate.keyboardInputSourceDidChange()
        }
    }
}

private final class TouchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A non-activating panel lets the user tap keys while the selected app keeps
/// its input focus. This is important because macOS has no system touch keyboard.
private final class KeyboardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private enum KeyboardOutput {
    case text(String, CGKeyCode? = nil, CGEventFlags = [])
    case keyCode(CGKeyCode, CGEventFlags = [])
}

/// Resolves characters for physical macOS key positions. The static map is a
/// safe Czech fallback for input sources that do not expose a Unicode layout.
private enum KeyboardLayout {
    static func keyCode(for text: String) -> CGKeyCode? {
        guard text.count == 1, let character = text.lowercased().unicodeScalars.first else { return nil }
        let codes: [UnicodeScalar: CGKeyCode] = [
            // The onscreen layout is Czech QWERTZ: Z and Y use the opposite
            // physical key positions from an American QWERTY keyboard.
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "y": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "z": 16,
            "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
            "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34,
            "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, ",": 43, "/": 44,
            " ": 49,
            // The accented top row uses the same physical keys as the digit
            // row. This makes Option shortcuts follow the Czech macOS layout;
            // in particular, ⌥ + ě (key code 19) produces @.
            ";": 50, "+": 18, "ě": 19, "š": 20, "č": 21, "ř": 23, "ž": 22,
            "ý": 26, "á": 28, "í": 25, "é": 29, "ú": 33, "ů": 39, "§": 41,
            "¨": 42, "<": 10
        ]
        return codes[character]
    }

    static func translatedText(for keyCode: CGKeyCode, modifiers: CGEventFlags) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return nil }
        let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        var deadKeyState: UInt32 = 0
        var outputLength = 0
        var output = [UniChar](repeating: 0, count: 8)
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.maskShift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.maskAlternate) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.maskAlphaShift) { carbonModifiers |= UInt32(alphaLock) }
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            carbonModifiers >> 8,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            output.count,
            &outputLength,
            &output
        )
        guard status == noErr, outputLength > 0 else { return nil }
        return String(utf16CodeUnits: output, count: outputLength)
    }

    static func isDeadKey(_ keyCode: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return false
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else { return false }
        let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        var deadKeyState: UInt32 = 0
        var outputLength = 0
        var output = [UniChar](repeating: 0, count: 8)
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.maskShift) { carbonModifiers |= UInt32(shiftKey) }
        if modifiers.contains(.maskAlternate) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.maskAlphaShift) { carbonModifiers |= UInt32(alphaLock) }
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDown),
            carbonModifiers >> 8,
            UInt32(LMGetKbdType()),
            0,
            &deadKeyState,
            output.count,
            &outputLength,
            &output
        )
        return status == noErr && deadKeyState != 0
    }
}

private enum KeyboardCommand {
    case output(KeyboardOutput)
    case shift
    case capsLock
    case modifier(CGEventFlags)
    case hideKeyboard
}

private struct KeyboardKey {
    let title: String
    let shiftedTitle: String?
    let command: KeyboardCommand
    let width: CGFloat
    let symbolName: String?
    let physicalKeyCode: CGKeyCode?

    init(
        _ title: String,
        shiftedTitle: String? = nil,
        command: KeyboardCommand,
        width: CGFloat = 1,
        symbolName: String? = nil,
        physicalKeyCode: CGKeyCode? = nil
    ) {
        self.title = title
        self.shiftedTitle = shiftedTitle
        self.command = command
        self.width = width
        self.symbolName = symbolName
        self.physicalKeyCode = physicalKeyCode
    }

    static func text(_ value: String, shifted: String? = nil, width: CGFloat = 1) -> KeyboardKey {
        KeyboardKey(value, shiftedTitle: shifted, command: .output(.text(value)), width: width)
    }

    static func character(
        _ fallback: String,
        shifted: String? = nil,
        keyCode: CGKeyCode,
        width: CGFloat = 1
    ) -> KeyboardKey {
        KeyboardKey(
            fallback,
            shiftedTitle: shifted,
            command: .output(.text(fallback)),
            width: width,
            physicalKeyCode: keyCode
        )
    }

    static func special(
        _ title: String,
        keyCode: CGKeyCode,
        width: CGFloat = 1,
        symbolName: String? = nil
    ) -> KeyboardKey {
        KeyboardKey(title, command: .output(.keyCode(keyCode)), width: width, symbolName: symbolName)
    }

    static func modifier(_ title: String, flags: CGEventFlags, width: CGFloat = 1) -> KeyboardKey {
        KeyboardKey(title, command: .modifier(flags), width: width)
    }

    var helpText: String? {
        if case .hideKeyboard = command {
            return "Skrýt dotykovou klávesnici"
        }
        guard case .output(.keyCode(let keyCode, _)) = command else { return nil }
        return switch keyCode {
        case 51: "Smazat znak vlevo"
        case 117: "Del — smazat znak vpravo"
        case 123: "Přesun vlevo"
        case 124: "Přesun vpravo"
        case 125: "Přesun dolů"
        case 126: "Přesun nahoru"
        case 115: "Home — začátek"
        case 119: "End — konec"
        case 116: "Page Up — o stránku nahoru"
        case 121: "Page Down — o stránku dolů"
        case 53: "Esc — zrušit"
        default: nil
        }
    }

    /// Returns the character that this physical key represents in the active
    /// macOS layout and falls back to the original Czech labels when needed.
    func textOutput(activeModifiers: CGEventFlags, capsLockActive: Bool) -> String? {
        guard case .output(.text(let text, _, _)) = command else { return nil }

        var layoutModifiers = activeModifiers.intersection([.maskShift, .maskAlternate])
        if capsLockActive { layoutModifiers.insert(.maskAlphaShift) }
        if let physicalKeyCode,
           let translated = KeyboardLayout.translatedText(for: physicalKeyCode, modifiers: layoutModifiers) {
            return translated
        }

        let shiftActive = activeModifiers.contains(.maskShift)
        let isLetter = text.rangeOfCharacter(from: .letters) != nil
        if shiftActive {
            if capsLockActive && isLetter {
                return text
            }
            return shiftedTitle ?? text.uppercased()
        }
        return capsLockActive && isLetter ? text.uppercased() : text
    }

    func isDeadKey(activeModifiers: CGEventFlags, capsLockActive: Bool) -> Bool {
        guard let physicalKeyCode else { return false }
        var layoutModifiers = activeModifiers.intersection([.maskShift, .maskAlternate])
        if capsLockActive { layoutModifiers.insert(.maskAlphaShift) }
        return KeyboardLayout.isDeadKey(physicalKeyCode, modifiers: layoutModifiers)
    }

    /// Shows the result of Option directly on the key. Command and Fn replace
    /// known keys with a compact action label instead of a noisy modifier
    /// prefix; unknown combinations keep their normal key label.
    func displayTitle(activeModifiers: CGEventFlags, capsLockActive: Bool) -> String? {
        let shiftActive = activeModifiers.contains(.maskShift)
        guard let text = textOutput(activeModifiers: activeModifiers, capsLockActive: capsLockActive) else {
            return nil
        }

        let key = text.lowercased()
        if activeModifiers.contains(.maskCommand) {
            if shiftActive && key == "z" { return "Znovu" }
            let commandActions = [
                "a": "Vše", "b": "Tučně", "c": "Kopie", "f": "Najít",
                "g": "Další", "h": "Skrýt", "i": "Kurzíva", "m": "Mini",
                "n": "Nové", "o": "Otevřít", "p": "Tisk", "q": "Konec",
                "s": "Uložit", "t": "Panel", "u": "Podtrh.", "v": "Vložit",
                "w": "Zavřít", "x": "Vyjmout", "z": "Zpět", ",": "Nast."
            ]
            return commandActions[key] ?? text
        }

        if activeModifiers.contains(.maskSecondaryFn) {
            let functionActions = [
                "a": "Dock", "c": "Centrum", "d": "Diktát", "h": "Plocha",
                "n": "Oznám.", "q": "Poznám."
            ]
            return functionActions[key] ?? text
        }

        return text
    }
}

private final class TouchKeyboardView: NSView {
    var onKeyPress: ((KeyboardOutput) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onHideKeyboard: (() -> Void)?

    private var activeModifiers: CGEventFlags = []
    private var isCapsLockEnabled = false
    private var isDeadKeyPending = false
    private var previewText = ""
    private var keys: [KeyboardKeyButton] = []
    private let keySpacing: CGFloat = 5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    required init?(coder: NSCoder) { nil }

    private func buildLayout() {
        let mainKeyboard = NSStackView()
        mainKeyboard.orientation = .vertical
        mainKeyboard.spacing = keySpacing
        mainKeyboard.alignment = .width
        mainKeyboard.distribution = .fillEqually
        mainKeyboard.translatesAutoresizingMaskIntoConstraints = false

        letterRows.forEach { mainKeyboard.addArrangedSubview(makeRow($0)) }

        let numpad = NumericKeypadView(spacing: keySpacing) { [weak self] output, button in
            self?.send(output, from: button)
        }
        numpad.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let arrowSeparator = NSBox()
        arrowSeparator.boxType = .separator
        arrowSeparator.translatesAutoresizingMaskIntoConstraints = false

        let arrows = makeColumn(arrowKeys, topSpacer: true)
        arrows.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSStackView(views: [mainKeyboard, separator, numpad, arrowSeparator, arrows])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = 5
        layout.translatesAutoresizingMaskIntoConstraints = false
        let specialKeys = makeRow(specialKeyRow)
        specialKeys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        addSubview(specialKeys)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: specialKeys.bottomAnchor, constant: keySpacing),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            arrowSeparator.widthAnchor.constraint(equalToConstant: 1),
            numpad.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.20),
            // Match the arrow column to one numeric-keypad cell: four cells
            // share the numpad width with three gaps between them.
            arrows.widthAnchor.constraint(
                equalTo: numpad.widthAnchor,
                multiplier: 0.25,
                constant: -(keySpacing * 0.75)
            ),
            mainKeyboard.heightAnchor.constraint(equalTo: layout.heightAnchor),
            numpad.heightAnchor.constraint(equalTo: layout.heightAnchor),
            arrows.heightAnchor.constraint(equalTo: layout.heightAnchor),
            specialKeys.leadingAnchor.constraint(equalTo: leadingAnchor),
            // The top row ends with the numeric keypad; arrows stay in their
            // own separate column to its right.
            specialKeys.trailingAnchor.constraint(equalTo: numpad.trailingAnchor),
            specialKeys.topAnchor.constraint(equalTo: topAnchor),
            specialKeys.heightAnchor.constraint(equalTo: layout.heightAnchor, multiplier: 0.2)
        ])
    }

    private var letterRows: [[KeyboardKey]] {
        [
            [
                .character(";", shifted: "°", keyCode: 50),
                .character("+", shifted: "1", keyCode: 18), .character("ě", shifted: "2", keyCode: 19),
                .character("š", shifted: "3", keyCode: 20), .character("č", shifted: "4", keyCode: 21),
                .character("ř", shifted: "5", keyCode: 23), .character("ž", shifted: "6", keyCode: 22),
                .character("ý", shifted: "7", keyCode: 26), .character("á", shifted: "8", keyCode: 28),
                .character("í", shifted: "9", keyCode: 25), .character("é", shifted: "0", keyCode: 29),
                .character("=", shifted: "%", keyCode: 24),
                .special("", keyCode: 51, width: 1.45, symbolName: "delete.left")
            ],
            [
                .special("", keyCode: 48, width: 1.35, symbolName: "arrow.right.to.line"),
                .character("q", shifted: "Q", keyCode: 12), .character("w", shifted: "W", keyCode: 13),
                .character("e", shifted: "E", keyCode: 14), .character("r", shifted: "R", keyCode: 15),
                .character("t", shifted: "T", keyCode: 17), .character("z", shifted: "Z", keyCode: 16),
                .character("u", shifted: "U", keyCode: 32), .character("i", shifted: "I", keyCode: 34),
                .character("o", shifted: "O", keyCode: 31), .character("p", shifted: "P", keyCode: 35),
                .character("ú", shifted: ")", keyCode: 33),
                .special("", keyCode: 36, width: 1.55, symbolName: "return")
            ],
            [
                KeyboardKey("⇪", command: .capsLock, width: 1.55),
                .character("a", shifted: "A", keyCode: 0), .character("s", shifted: "S", keyCode: 1),
                .character("d", shifted: "D", keyCode: 2), .character("f", shifted: "F", keyCode: 3),
                .character("g", shifted: "G", keyCode: 5), .character("h", shifted: "H", keyCode: 4),
                .character("j", shifted: "J", keyCode: 38), .character("k", shifted: "K", keyCode: 40),
                .character("l", shifted: "L", keyCode: 37), .character("ů", shifted: "\"", keyCode: 39),
                .character("§", shifted: "!", keyCode: 41), .character("¨", shifted: "^", keyCode: 42)
            ],
            [
                KeyboardKey("", command: .shift, width: 1.75, symbolName: "shift"),
                .character("<", shifted: ">", keyCode: 10), .character("y", shifted: "Y", keyCode: 6),
                .character("x", shifted: "X", keyCode: 7), .character("c", shifted: "C", keyCode: 8),
                .character("v", shifted: "V", keyCode: 9), .character("b", shifted: "B", keyCode: 11),
                .character("n", shifted: "N", keyCode: 45), .character("m", shifted: "M", keyCode: 46),
                .character(",", shifted: "<", keyCode: 43), .character(".", shifted: ">", keyCode: 47),
                .character("-", shifted: "_", keyCode: 44),
                KeyboardKey("", command: .shift, width: 1.75, symbolName: "shift")
            ],
            [
                .modifier("fn", flags: .maskSecondaryFn, width: 1.1),
                .modifier("⌃", flags: .maskControl, width: 1.1),
                .modifier("⌥", flags: .maskAlternate, width: 1.1),
                .modifier("⌘", flags: .maskCommand, width: 1.1),
                .special("", keyCode: 49, width: 5.6, symbolName: "space"),
                .modifier("⌘", flags: .maskCommand, width: 1.1),
                .modifier("⌥", flags: .maskAlternate, width: 1.1)
            ]
        ]
    }

    private var specialKeyRow: [KeyboardKey] {
        [
            .special("Esc", keyCode: 53, width: 1.15),
            .special("F1", keyCode: 122), .special("F2", keyCode: 120),
            .special("F3", keyCode: 99), .special("F4", keyCode: 118),
            .special("F5", keyCode: 96), .special("F6", keyCode: 97),
            .special("F7", keyCode: 98), .special("F8", keyCode: 100),
            .special("F9", keyCode: 101), .special("F10", keyCode: 109),
            .special("F11", keyCode: 103), .special("F12", keyCode: 111),
            .special("Home", keyCode: 115, width: 1.3),
            .special("Pg↑", keyCode: 116, width: 1.25),
            .special("Pg↓", keyCode: 121, width: 1.25),
            .special("End", keyCode: 119, width: 1.3),
            .special("Del", keyCode: 117, width: 1.15),
            // This follows the iPad keyboard-dismiss affordance, but keeps
            // the control in the keyboard's first row where it is reachable
            // without covering the target app.
            KeyboardKey(
                "",
                command: .hideKeyboard,
                width: 1.15,
                symbolName: "keyboard.chevron.compact.down"
            )
        ]
    }

    private var arrowKeys: [KeyboardKey] {
        [
            .special("↑", keyCode: 126), .special("←", keyCode: 123),
            .special("↓", keyCode: 125), .special("→", keyCode: 124)
        ]
    }

    private func makeRow(_ descriptors: [KeyboardKey]) -> KeyboardRowView {
        let buttons = descriptors.map { descriptor -> KeyboardKeyButton in
            let button = KeyboardKeyButton(key: descriptor)
            button.target = self
            button.action = #selector(pressKey(_:))
            keys.append(button)
            return button
        }
        return KeyboardRowView(buttons: buttons, spacing: keySpacing)
    }

    private func makeColumn(_ descriptors: [KeyboardKey], topSpacer: Bool = false) -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.distribution = .fillEqually
        column.spacing = keySpacing
        if topSpacer {
            column.addArrangedSubview(NSView())
        }
        descriptors.forEach { descriptor in
            let button = KeyboardKeyButton(key: descriptor)
            button.target = self
            button.action = #selector(pressKey(_:))
            keys.append(button)
            column.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return column
    }

    @objc private func pressKey(_ sender: KeyboardKeyButton) {
        switch sender.key.command {
        case .output(let output):
            if case .text = output, let keyCode = sender.key.physicalKeyCode {
                let isDeadKey = sender.key.isDeadKey(
                    activeModifiers: activeModifiers,
                    capsLockActive: isCapsLockEnabled
                )
                if isDeadKeyPending {
                    isDeadKeyPending = isDeadKey
                    send(.keyCode(keyCode), from: sender, includeVirtualCapsLock: true)
                } else if isDeadKey {
                    isDeadKeyPending = true
                    send(.keyCode(keyCode), from: sender, includeVirtualCapsLock: true)
                } else if let text = sender.key.textOutput(
                    activeModifiers: activeModifiers,
                    capsLockActive: isCapsLockEnabled
                ) {
                    send(.text(text, keyCode), from: sender)
                }
            } else {
                isDeadKeyPending = false
                send(output, from: sender)
            }
        case .shift:
            toggleModifier(.maskShift)
            sender.flash()
        case .capsLock:
            isCapsLockEnabled.toggle()
            updateKeyAppearance()
            sender.flash()
        case .modifier(let flags):
            toggleModifier(flags)
            sender.flash()
        case .hideKeyboard:
            sender.flash()
            onHideKeyboard?()
        }
    }

    private func send(
        _ output: KeyboardOutput,
        from button: KeyboardKeyButton,
        includeVirtualCapsLock: Bool = false
    ) {
        button.flash()
        var outputModifiers = activeModifiers
        if includeVirtualCapsLock && isCapsLockEnabled {
            outputModifiers.insert(.maskAlphaShift)
        }
        let outputWithModifiers: KeyboardOutput
        switch output {
        case .text(let text, let keyCode, _):
            outputWithModifiers = .text(text, keyCode, outputModifiers)
        case .keyCode(let keyCode, _):
            outputWithModifiers = .keyCode(keyCode, outputModifiers)
        }
        onKeyPress?(outputWithModifiers)
        switch output {
        case .text(let text, _, _):
            previewText.append(contentsOf: text)
        case .keyCode(let keyCode, _):
            switch keyCode {
            case 51:
                guard !previewText.isEmpty else { break }
                previewText.removeLast()
            case 36:
                previewText.append("↵")
            case 48:
                previewText.append("⇥")
            case 49:
                previewText.append(" ")
            default:
                break
            }
        }
        onTextChanged?(previewText)
        clearModifiers()
    }

    func replacePreviewText(_ text: String) {
        guard previewText != text else { return }
        previewText = text
        onTextChanged?(previewText)
    }

    func reloadKeyboardLayout() {
        isDeadKeyPending = false
        updateKeyAppearance()
    }

    private func toggleModifier(_ flags: CGEventFlags) {
        if activeModifiers.contains(flags) {
            activeModifiers.remove(flags)
        } else {
            activeModifiers.insert(flags)
        }
        updateKeyAppearance()
    }

    private func clearModifiers() {
        guard !activeModifiers.isEmpty else { return }
        activeModifiers = []
        updateKeyAppearance()
    }

    private func updateKeyAppearance() {
        keys.forEach {
            $0.updateAppearance(
                activeModifiers: activeModifiers,
                capsLockEnabled: isCapsLockEnabled
            )
        }
    }
}

/// Each row calculates its button frames from the same available width. Unlike
/// `NSStackView.fillProportionally`, this keeps every row flush on both sides
/// while still allowing wider Return, Shift and Space keys.
private final class KeyboardRowView: NSView {
    private let buttons: [KeyboardKeyButton]
    private let spacing: CGFloat

    init(buttons: [KeyboardKeyButton], spacing: CGFloat) {
        self.buttons = buttons
        self.spacing = spacing
        super.init(frame: .zero)
        buttons.forEach(addSubview)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let totalWeight = buttons.reduce(CGFloat.zero) { $0 + $1.key.width }
        guard totalWeight > 0 else { return }
        let usableWidth = max(0, bounds.width - spacing * CGFloat(max(0, buttons.count - 1)))
        let unit = usableWidth / totalWeight
        var x = bounds.minX
        for button in buttons {
            let width = button.key.width * unit
            button.frame = NSRect(x: x, y: bounds.minY, width: width, height: bounds.height)
            x += width + spacing
        }
    }
}

/// Mirrors the compact 4×5 numeric section of an extended Apple keyboard:
/// 0 spans two columns and Return spans the bottom two rows.
private final class NumericKeypadView: NSView {
    private struct Item {
        let button: KeyboardKeyButton
        let column: Int
        let row: Int
        let columnSpan: Int
        let rowSpan: Int
    }

    private let spacing: CGFloat
    private let onKeyPress: (KeyboardOutput, KeyboardKeyButton) -> Void
    private var items: [Item] = []

    init(spacing: CGFloat, onKeyPress: @escaping (KeyboardOutput, KeyboardKeyButton) -> Void) {
        self.spacing = spacing
        self.onKeyPress = onKeyPress
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        add(.special("", keyCode: 51, symbolName: "delete.left"), column: 0, row: 0)
        add(.text("="), column: 1, row: 0)
        add(.text("/"), column: 2, row: 0)
        add(.text("*"), column: 3, row: 0)
        add(.text("7"), column: 0, row: 1)
        add(.text("8"), column: 1, row: 1)
        add(.text("9"), column: 2, row: 1)
        add(.text("-"), column: 3, row: 1)
        add(.text("4"), column: 0, row: 2)
        add(.text("5"), column: 1, row: 2)
        add(.text("6"), column: 2, row: 2)
        add(.text("+"), column: 3, row: 2)
        add(.text("1"), column: 0, row: 3)
        add(.text("2"), column: 1, row: 3)
        add(.text("3"), column: 2, row: 3)
        add(.special("", keyCode: 36, symbolName: "return"), column: 3, row: 3, rowSpan: 2)
        add(.text("0"), column: 0, row: 4, columnSpan: 2)
        add(.text("."), column: 2, row: 4)
    }

    required init?(coder: NSCoder) { nil }

    private func add(
        _ key: KeyboardKey,
        column: Int,
        row: Int,
        columnSpan: Int = 1,
        rowSpan: Int = 1
    ) {
        let button = KeyboardKeyButton(key: key)
        button.target = self
        button.action = #selector(pressKey(_:))
        addSubview(button)
        items.append(Item(button: button, column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan))
    }

    @objc private func pressKey(_ sender: KeyboardKeyButton) {
        if case .output(let output) = sender.key.command {
            onKeyPress(output, sender)
        }
    }

    override func layout() {
        super.layout()
        let cellWidth = (bounds.width - spacing * 3) / 4
        let cellHeight = (bounds.height - spacing * 4) / 5
        guard cellWidth > 0, cellHeight > 0 else { return }
        for item in items {
            let x = bounds.minX + CGFloat(item.column) * (cellWidth + spacing)
            // The first visual row is at the top of an AppKit coordinate space.
            let y = bounds.maxY - CGFloat(item.row + item.rowSpan) * cellHeight - CGFloat(item.row + item.rowSpan - 1) * spacing
            let width = CGFloat(item.columnSpan) * cellWidth + CGFloat(item.columnSpan - 1) * spacing
            let height = CGFloat(item.rowSpan) * cellHeight + CGFloat(item.rowSpan - 1) * spacing
            item.button.frame = NSRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// The panel is anchored at the bottom, so dragging this top-right grip changes
/// its width and height without making the keyboard appear to float away.
private final class KeyboardResizeHandle: NSView {
    var onResize: ((NSSize) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12.5
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        toolTip = "Tažením změnit velikost klávesnice"
        setAccessibilityLabel("Změnit velikost klávesnice")

        let imageView = NSImageView(image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil) ?? NSImage())
        imageView.contentTintColor = .secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 13),
            imageView.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let initialFrame = window.frame
        // Window-relative coordinates change whenever we re-center the panel.
        // Screen coordinates remain stable throughout the drag and prevent jumps.
        let start = NSEvent.mouseLocation
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let minSize = window.minSize

        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            let maximumWidth = screenFrame.width - 28
            let maximumHeight = screenFrame.maxY - initialFrame.minY - 14
            // The right grip still follows the pointer, but both horizontal edges
            // move equally so the keyboard stays centered above the Dock.
            let width = min(maximumWidth, max(minSize.width, initialFrame.width + 2 * (point.x - start.x)))
            let height = min(maximumHeight, max(minSize.height, initialFrame.height + point.y - start.y))
            let frame = NSRect(
                x: screenFrame.midX - width / 2,
                y: initialFrame.minY,
                width: width,
                height: height
            )
            window.setFrame(frame, display: true)
            onResize?(frame.size)
        }
    }
}

private final class KeyboardKeyButton: NSButton {
    let key: KeyboardKey
    private var isActiveModifier = false

    init(key: KeyboardKey) {
        self.key = key
        super.init(frame: .zero)
        bezelStyle = .regularSquare
        isBordered = false
        imagePosition = .imageOnly
        font = .systemFont(ofSize: 15, weight: .medium)
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        let label = key.helpText ?? (key.title.isEmpty ? (key.symbolName ?? "Klávesa") : key.title)
        setAccessibilityLabel(label)
        toolTip = key.helpText
        translatesAutoresizingMaskIntoConstraints = false
        updateAppearance(activeModifiers: [], capsLockEnabled: false)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // The available cell width and height both contribute to the scale, so
        // glyphs remain visually proportional while the panel is resized.
        let horizontalScale = (bounds.width / max(key.width, 1)) / 46
        let verticalScale = bounds.height / 49
        let scale = min(1.9, max(0.78, min(horizontalScale, verticalScale)))
        let fontSize = 15 * scale
        font = .systemFont(ofSize: fontSize, weight: .medium)
        image?.size = NSSize(width: 16 * scale, height: 16 * scale)
        layer?.cornerRadius = max(8, min(14, bounds.height * 0.17))
    }

    func updateAppearance(activeModifiers: CGEventFlags, capsLockEnabled: Bool) {
        if let symbolName = key.symbolName {
            image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            imagePosition = .imageOnly
        } else {
            image = nil
            imagePosition = .noImage
            title = key.displayTitle(
                activeModifiers: activeModifiers,
                capsLockActive: capsLockEnabled
            ) ?? key.title
            if case .output(.text) = key.command {
                setAccessibilityLabel(title)
            }
        }

        switch key.command {
        case .shift:
            isActiveModifier = activeModifiers.contains(.maskShift)
        case .capsLock:
            isActiveModifier = capsLockEnabled
        case .modifier(let flags):
            isActiveModifier = activeModifiers.contains(flags)
        case .output, .hideKeyboard:
            isActiveModifier = false
        }
        layer?.backgroundColor = baseBackgroundColor.cgColor
    }

    func flash() {
        layer?.removeAllAnimations()
        let flashColor = NSColor.white.withAlphaComponent(0.48).cgColor
        let baseColor = baseBackgroundColor.cgColor
        layer?.backgroundColor = flashColor
        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = flashColor
        animation.toValue = baseColor
        animation.duration = 0.16
        layer?.backgroundColor = baseColor
        layer?.add(animation, forKey: "keyboardFlash")
    }

    private var baseBackgroundColor: NSColor {
        isActiveModifier ? .controlAccentColor : NSColor.white.withAlphaComponent(0.18)
    }
}

private class TrafficLightButton: NSButton {
    private let circleLayer = CAShapeLayer()

    init(color: NSColor, symbol: String, label: String, diameter: CGFloat) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        imagePosition = .imageOnly
        contentTintColor = .white
        bezelStyle = .regularSquare
        isBordered = false
        wantsLayer = true
        // Keep the visual itself circular even if AppKit gives the button a
        // non-square layout frame (for example when the Dock size changes).
        circleLayer.fillColor = color.cgColor
        circleLayer.strokeColor = NSColor.white.withAlphaComponent(0.25).cgColor
        circleLayer.lineWidth = 1
        layer?.addSublayer(circleLayer)
        toolTip = label
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool {
        didSet {
            // The traffic-light circle is custom-drawn, so AppKit's default
            // disabled appearance would otherwise not be visible.
            alphaValue = isEnabled ? 1 : 0.32
        }
    }

    override func layout() {
        super.layout()
        let diameter = min(bounds.width, bounds.height)
        let circleFrame = NSRect(
            x: (bounds.width - diameter) / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        circleLayer.frame = circleFrame
        circleLayer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: circleFrame.size), transform: nil)
    }
}

/// Keeps the normal short press, but prevents it after a deliberate hold.
private final class LongPressTrafficLightButton: TrafficLightButton {
    var onLongPress: ((NSButton) -> Void)?
    private var suppressNextAction = false

    override func mouseDown(with event: NSEvent) {
        suppressNextAction = false
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(triggerLongPress(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        super.mouseDown(with: event)
        timer.invalidate()
        suppressNextAction = false
    }

    @objc private func triggerLongPress(_ timer: Timer) {
        suppressNextAction = true
        onLongPress?(self)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard !suppressNextAction else { return false }
        return super.sendAction(action, to: target)
    }
}

private enum WindowAction: Equatable {
    case close, minimize, zoom

    var attribute: CFString {
        switch self {
        case .close: "AXCloseButton" as CFString
        case .minimize: "AXMinimizeButton" as CFString
        case .zoom: "AXZoomButton" as CFString
        }
    }
}

private struct WindowTarget {
    let pid: pid_t

    func perform(_ action: WindowAction) -> Bool {
        perform(action, accessibilityAction: "AXPress" as CFString)
    }

    func supports(_ action: WindowAction) -> Bool {
        guard let button = controlButton(for: action) else { return false }

        var actionsValue: CFArray?
        guard AXUIElementCopyActionNames(button, &actionsValue) == .success,
              let actions = actionsValue as? [String] else { return false }
        return actions.contains("AXPress")
    }

    func hasFocusedWindow() -> Bool {
        focusedWindow() != nil
    }

    func showZoomMenu() -> Bool {
        perform(.zoom, accessibilityAction: "AXShowMenu" as CFString)
    }

    func send(_ output: KeyboardOutput) {
        switch output {
        case .text(let text, let keyCode, let flags):
            postText(text, keyCode: keyCode, flags: flags)
        case .keyCode(let keyCode, let flags):
            postKeyCode(keyCode, flags: flags)
        }
    }

    func focusedText() -> String? {
        let application = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            "AXFocusedUIElement" as CFString,
            &focusedValue
        ) == .success,
        let focusedElement = focusedValue else { return nil }

        var textValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            "AXValue" as CFString,
            &textValue
        ) == .success else { return nil }
        return textValue as? String
    }

    private func postText(_ text: String, keyCode: CGKeyCode?, flags: CGEventFlags) {
        // Chromium-based browsers (including Brave) do not reliably accept a
        // process-targeted Unicode-only event in the omnibox. Give every key
        // with a known physical position its key code and inject it at
        // the HID event tap. The Unicode payload keeps the text exact, while
        // the key code lets browser controls handle it like a real keyboard.
        let characters = Array(text.utf16)
        guard !characters.isEmpty,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode ?? shortcutKeyCode(for: text) ?? 0,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keyCode ?? shortcutKeyCode(for: text) ?? 0,
                keyDown: false
              ) else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        keyUp.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: characters)
        postAsKeyboardInput(keyDown)
        postAsKeyboardInput(keyUp)
    }

    private func shortcutKeyCode(for text: String) -> CGKeyCode? {
        KeyboardLayout.keyCode(for: text)
    }

    private func postKeyCode(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return }
        keyDown.flags = flags
        keyUp.flags = flags
        postAsKeyboardInput(keyDown)
        postAsKeyboardInput(keyUp)
    }

    private func postAsKeyboardInput(_ event: CGEvent) {
        // The keyboard panel never activates, therefore the app the user was
        // editing remains frontmost. Posting at the HID tap follows the normal
        // system input route rather than bypassing browser text controls by
        // sending a private event directly to their process.
        event.post(tap: .cghidEventTap)
    }

    private func perform(_ action: WindowAction, accessibilityAction: CFString) -> Bool {
        guard let button = controlButton(for: action) else { return false }
        return AXUIElementPerformAction(button, accessibilityAction) == .success
    }

    private func controlButton(for action: WindowAction) -> AXUIElement? {
        guard let window = focusedWindow() else { return nil }

        var buttonValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, action.attribute, &buttonValue) == .success,
              let button = buttonValue else { return nil }
        return (button as! AXUIElement)
    }

    private func focusedWindow() -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, "AXFocusedWindow" as CFString, &focusedValue) == .success,
              let window = focusedValue else { return nil }
        return (window as! AXUIElement)
    }
}
