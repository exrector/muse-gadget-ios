import SwiftUI
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene,
              let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

        let window = UIWindow(windowScene: windowScene)
        // iOS 15's TextEditor has no other way to drop its white background.
        UITextView.appearance().backgroundColor = .clear
        // Solid on purpose, like the app's other bars: older devices struggle with blur.
        let tabBar = UITabBarAppearance()
        tabBar.configureWithOpaqueBackground()
        UITabBar.appearance().standardAppearance = tabBar
        UITabBar.appearance().scrollEdgeAppearance = tabBar
        self.window = window
        showRoot(environment: appDelegate.environment)
        window.makeKeyAndVisible()
    }

    func showRoot(environment: AppEnvironment) {
        window?.rootViewController = UIHostingController(rootView: MuseAppView(environment: environment))
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }
        for context in URLContexts { appDelegate.environment.shortcuts.handleCallback(context.url) }
    }
}

