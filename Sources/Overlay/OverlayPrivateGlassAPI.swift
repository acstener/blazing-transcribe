import AppKit
import ObjectiveC.runtime

struct OverlayPrivateGlassTuning {
    let variant: Int
    let scrimState: Int
    let subduedState: Int
}

enum OverlayPrivateGlassAPI {
    @available(macOS 26.0, *)
    static func apply(
        to glassView: NSGlassEffectView,
        tuning: OverlayPrivateGlassTuning? = nil,
        context: String? = nil
    ) {
        guard OverlayDiagnostics.usePrivateGlassAPI else { return }

        let resolvedTuning = tuning ?? OverlayPrivateGlassTuning(
            variant: OverlayDiagnostics.privateGlassVariant,
            scrimState: OverlayDiagnostics.privateGlassScrimState,
            subduedState: OverlayDiagnostics.privateGlassSubduedState
        )

        var changes: [String] = []
        if callIntSelector("set_variant:", on: glassView, value: resolvedTuning.variant) {
            changes.append("variant=\(resolvedTuning.variant)")
        }
        if callIntSelector("set_scrimState:", on: glassView, value: resolvedTuning.scrimState) {
            changes.append("scrim=\(resolvedTuning.scrimState)")
        }
        if callIntSelector("set_subduedState:", on: glassView, value: resolvedTuning.subduedState) {
            changes.append("subdued=\(resolvedTuning.subduedState)")
        }

        if !changes.isEmpty {
            let contextSuffix = context.map { "[\($0)]" } ?? ""
            print("[OverlayPrivate] glass\(contextSuffix) \(changes.joined(separator: ","))")
        }
    }

    static func apply(to window: NSWindow) {
        guard OverlayDiagnostics.usePrivateGlassAPI, OverlayDiagnostics.forcePrivateActiveAppearance else { return }

        var changes: [String] = []
        if callBoolSelector("_setHasActiveAppearance:", on: window, value: true) {
            changes.append("hasActiveAppearance=1")
        }
        if callBoolSelector("_setForceActiveControls:", on: window, value: true) {
            changes.append("forceActiveControls=1")
        }
        if callBoolSelector("_setForceMainAppearance:", on: window, value: true) {
            changes.append("forceMainAppearance=1")
        }
        if callVoidSelector("acquireKeyAppearance", on: window) {
            changes.append("acquireKeyAppearance")
        }
        if callVoidSelector("acquireMainAppearance", on: window) {
            changes.append("acquireMainAppearance")
        }

        if !changes.isEmpty {
            print("[OverlayPrivate] window \(changes.joined(separator: ","))")
        }
    }

    private static func callIntSelector(_ selectorName: String, on object: NSObject, value: Int) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(object), selector) else {
            return false
        }

        typealias Function = @convention(c) (AnyObject, Selector, Int) -> Void
        let implementation = method_getImplementation(method)
        unsafeBitCast(implementation, to: Function.self)(object, selector, value)
        return true
    }

    private static func callBoolSelector(_ selectorName: String, on object: NSObject, value: Bool) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(object), selector) else {
            return false
        }

        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        let implementation = method_getImplementation(method)
        unsafeBitCast(implementation, to: Function.self)(object, selector, value)
        return true
    }

    private static func callVoidSelector(_ selectorName: String, on object: NSObject) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(object_getClass(object), selector) else {
            return false
        }

        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let implementation = method_getImplementation(method)
        unsafeBitCast(implementation, to: Function.self)(object, selector)
        return true
    }
}
