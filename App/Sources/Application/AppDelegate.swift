import UIKit
import WidgetKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    private(set) var environment = AppEnvironment()

    /// Returns the app to the state of a first launch and shows the first setup step.
    func resetToFirstLaunch() {
        environment.shutdown()
        AppEnvironment.eraseStoredData()
        environment = AppEnvironment()
        UIApplication.shared.isIdleTimerDisabled = false
        WidgetCenter.shared.reloadAllTimelines()
        for scene in UIApplication.shared.connectedScenes {
            (scene.delegate as? SceneDelegate)?.showRoot(environment: environment)
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

