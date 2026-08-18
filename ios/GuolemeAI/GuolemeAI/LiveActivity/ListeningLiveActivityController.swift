import ActivityKit
import Foundation
import UIKit

enum ListeningLiveActivityController {
    static func start(appName: String, modeLabel: String, statusLine: String, listeningLabel: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = ListeningAttributes(appName: appName)
        let state = ListeningAttributes.ContentState(
            isListening: true,
            modeLabel: modeLabel,
            statusLine: statusLine,
            listeningLabel: listeningLabel
        )
        do {
            _ = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
        } catch {
            // Live Activity is optional; ignore authorization / entitlement gaps during development.
        }
    }

    static func update(modeLabel: String, statusLine: String, listeningLabel: String) {
        Task {
            for activity in Activity<ListeningAttributes>.activities {
                await activity.update(.init(
                    state: .init(
                        isListening: true,
                        modeLabel: modeLabel,
                        statusLine: statusLine,
                        listeningLabel: listeningLabel
                    ),
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
