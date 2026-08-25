import CoreServices
import Foundation

/// Silent read of the Automation (TCC) grant for Messages, so the menu can say
/// whether a send would be allowed BEFORE the lid closes. Behind a protocol so
/// tests never touch the real AppleEvent API.
protocol AutomationPermissionProbing: AnyObject, Sendable {
    /// Never prompts and never launches Messages.
    func probeMessages() -> AutomationPermission
}

/// PROBE FILE (structural-isolation boundary): the ONLY place
/// `AEDeterminePermissionToAutomateTarget` may appear
/// (`LidGuardStructureTests` enforces this).
///
/// UNPRIVILEGED and side-effect free: `askUserIfNeeded: false` means the call
/// reports the current grant and NEVER raises the "NapCat wants to control
/// Messages" prompt. That prompt is raised deliberately, and only by the
/// user-initiated config-time test send, while the user is present.
final class AppleEventAutomationProbe: AutomationPermissionProbing, @unchecked Sendable {
    func probeMessages() -> AutomationPermission {
        var target = AEAddressDesc()
        let bundleID = Array(LidGuardTuning.messagesBundleID.utf8)
        let createStatus = bundleID.withUnsafeBufferPointer { buffer in
            AECreateDesc(typeApplicationBundleID, buffer.baseAddress, buffer.count, &target)
        }
        // AECreateDesc reports OSErr (Int16); widen it for the shared mapping.
        guard createStatus == noErr else { return .unknown(Int32(createStatus)) }
        defer { AEDisposeDesc(&target) }
        // Wildcard class/ID = "may we send this target anything at all".
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        return LidGuardPolicy.automationPermission(fromStatus: status)
    }
}
