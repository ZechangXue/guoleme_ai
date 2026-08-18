import ActivityKit
import Foundation
import UIKit

enum ListeningLiveActivityController {
    static func start(modeLabel: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ListeningAttributes(appName: "过了么AI")
        let state = ListeningAttributes.ContentState(
            isListening: true,
            modeLabel: modeLabel,
            statusLine: "把手机靠近电脑扬声器"
        )
        do {
            _ = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            // Live Activity is optional; ignore authorization / entitlement gaps during development.
        }
    }

    static func update(modeLabel: String, statusLine: String) {
        Task {
            for activity in Activity<ListeningAttributes>.activities {
                await activity.update(.init(
                    state: .init(isListening: true, modeLabel: modeLabel, statusLine: statusLine),
                    staleDate: nil
                ))
            }
        }
    }

    static func end() {
        Task {
            for activity in Activity<ListeningAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
