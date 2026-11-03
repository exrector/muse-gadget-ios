import UIKit

final class MainViewController: UIViewController {
    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let stateLabel = UILabel()
    private let nameLabel = UILabel()
    private let captionLabel = UILabel()
    private let logView = UITextView()
    private let pairButton = UIButton(type: .system)
    private let tokenStatusLabel = UILabel()
    private let tokenButton = UIButton(type: .system)
    private let pasteTokenButton = UIButton(type: .system)

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
        title = "Muse Gadget Legacy"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureNavigation()
        configureLayout()
        bindEnvironment()
        render(environment.pairing.state)
    }

    private func configureNavigation() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Permissions",
            style: .plain,
            target: self,
            action: #selector(showPermissions)
        )
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 32, right: 20)
        stack.isLayoutMarginsRelativeArrangement = true

        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        let hero = UILabel()
        hero.text = "TURN THIS DEVICE\nINTO A MUSE COMPANION."
        hero.numberOfLines = 0
        hero.font = .monospacedSystemFont(ofSize: 27, weight: .bold)
        hero.textColor = .label
        stack.addArrangedSubview(hero)

        let explanation = UILabel()
        explanation.text = "Use this iPhone or iPad as the gadget. Keep your main phone nearby to finish setup in Muse. Bluetooth is used only while pairing."
        explanation.numberOfLines = 0
        explanation.font = .preferredFont(forTextStyle: .body)
        explanation.textColor = .secondaryLabel
        stack.addArrangedSubview(explanation)

#if targetEnvironment(simulator)
        let simulatorWarning = UILabel()
        simulatorWarning.numberOfLines = 0
        simulatorWarning.font = .preferredFont(forTextStyle: .headline)
        simulatorWarning.textColor = .systemRed
        simulatorWarning.text = "Simulator can preview this interface, but cannot advertise as a Bluetooth gadget. Install the app on a physical iPhone or iPad to pair."
        stack.addArrangedSubview(card(title: "PHYSICAL DEVICE REQUIRED", content: simulatorWarning))
#endif

        let steps = UILabel()
        steps.numberOfLines = 0
        steps.font = .preferredFont(forTextStyle: .body)
        steps.text = "1  Add your personal Muse Gadget SDK token.\n\n2  Tap Start pairing on this device.\n\n3  On your main phone open Muse → Settings → Devices, enable Developer mode, then tap +.\n\n4  Choose the device name shown below and approve setup."
        stack.addArrangedSubview(card(title: "SETUP — TWO PHONES", content: steps))

        tokenStatusLabel.numberOfLines = 0
        tokenStatusLabel.font = .preferredFont(forTextStyle: .headline)
        pasteTokenButton.configuration = .borderedProminent()
        pasteTokenButton.configuration?.title = "Paste token from clipboard"
        pasteTokenButton.configuration?.image = UIImage(systemName: "doc.on.clipboard")
        pasteTokenButton.configuration?.imagePadding = 8
        pasteTokenButton.configuration?.cornerStyle = .large
        pasteTokenButton.addTarget(self, action: #selector(pasteSDKToken), for: .touchUpInside)
        pasteTokenButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        tokenButton.configuration = .bordered()
        tokenButton.configuration?.cornerStyle = .large
        tokenButton.addTarget(self, action: #selector(editSDKToken), for: .touchUpInside)

        let getTokenButton = UIButton(type: .system)
        getTokenButton.setTitle("Get a token at gadgets.muse.ai ↗", for: .normal)
        getTokenButton.contentHorizontalAlignment = .leading
        getTokenButton.addTarget(self, action: #selector(openTokenWebsite), for: .touchUpInside)

        let clipboardHint = UILabel()
        clipboardHint.text = "Copy the token on your Mac or main iPhone, then tap the button below."
        clipboardHint.numberOfLines = 0
        clipboardHint.font = .preferredFont(forTextStyle: .subheadline)
        clipboardHint.textColor = .secondaryLabel

        let tokenStack = UIStackView(arrangedSubviews: [tokenStatusLabel, clipboardHint, pasteTokenButton, tokenButton, getTokenButton])
        tokenStack.axis = .vertical
        tokenStack.spacing = 10
        stack.addArrangedSubview(card(title: "PERSONAL SDK TOKEN", content: tokenStack))

        nameLabel.font = .monospacedSystemFont(ofSize: 20, weight: .semibold)
        nameLabel.text = environment.identity.bluetoothName
        stack.addArrangedSubview(card(title: "DEVICE IDENTITY", content: nameLabel))

        stateLabel.font = .preferredFont(forTextStyle: .headline)
        stateLabel.numberOfLines = 0
        stack.addArrangedSubview(card(title: "PAIRING STATE", content: stateLabel))

        captionLabel.text = "No caption received"
        captionLabel.numberOfLines = 0
        captionLabel.font = .preferredFont(forTextStyle: .title2)
        captionLabel.textAlignment = .center
        captionLabel.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(card(title: "MUSE DISPLAY", content: captionLabel, minimumHeight: 150))

        if #available(iOS 15.0, *) {
            pairButton.configuration = .filled()
            pairButton.configuration?.title = "Start pairing"
            pairButton.configuration?.cornerStyle = .large
        } else {
            pairButton.backgroundColor = .systemBlue
            pairButton.setTitleColor(.white, for: .normal)
            pairButton.setTitle("Start pairing", for: .normal)
            pairButton.layer.cornerRadius = 14
        }
        pairButton.addTarget(self, action: #selector(startPairing), for: .touchUpInside)
        pairButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stack.addArrangedSubview(pairButton)

        let commandsLabel = UILabel()
        commandsLabel.numberOfLines = 0
        commandsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        commandsLabel.text = environment.commands.names.joined(separator: "\n")
        stack.addArrangedSubview(card(title: "EXPLICIT IOS COMMANDS", content: commandsLabel))

        logView.isEditable = false
        logView.backgroundColor = .clear
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.text = "Protocol log contains no tokens or command payloads.\n"
        stack.addArrangedSubview(card(title: "DIAGNOSTICS", content: logView, minimumHeight: 220))
        refreshTokenUI()
    }

    private func card(title: String, content: UIView, minimumHeight: CGFloat = 0) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 16

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        titleLabel.textColor = .secondaryLabel

        let inner = UIStackView(arrangedSubviews: [titleLabel, content])
        inner.axis = .vertical
        inner.spacing = 10
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14)
        ])
        if minimumHeight > 0 { card.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true }
        return card
    }

    private func bindEnvironment() {
        environment.pairing.onStateChange = { [weak self] state in self?.render(state) }
        environment.pairing.onLog = { [weak self] message in self?.appendLog(message) }
        NotificationCenter.default.addObserver(
            forName: .museCaptionChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.captionLabel.text = note.object as? String ?? ""
        }
    }

    private func render(_ state: PairingCoordinator.State) {
        stateLabel.text = state.title
        refreshTokenUI()
        let title: String
        let showActivity: Bool
        switch state {
        case .paired:
            stateLabel.textColor = .systemGreen
            title = "Pair again"
            showActivity = false
        case .bluetooth:
            stateLabel.textColor = .systemOrange
            title = "Starting Bluetooth…"
            showActivity = true
        case .advertising:
            stateLabel.textColor = .systemGreen
            title = "Pairing open — waiting for Muse"
            showActivity = true
        case .connected, .encrypted, .provisioning:
            stateLabel.textColor = .systemBlue
            title = "Completing secure pairing…"
            showActivity = true
        case .failed:
            stateLabel.textColor = .systemRed
            title = "Try pairing again"
            showActivity = false
        default:
            stateLabel.textColor = .label
            title = "Start pairing"
            showActivity = false
        }
        setPairButton(title: title, showActivity: showActivity)
    }

    private func setPairButton(title: String, showActivity: Bool) {
        if #available(iOS 15.0, *) {
            pairButton.configuration?.title = title
            pairButton.configuration?.showsActivityIndicator = showActivity
        } else {
            let displayTitle = showActivity ? "\(title) …" : title
            pairButton.setTitle(displayTitle, for: .normal)
        }
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logView.text += "\(formatter.string(from: Date()))  \(message)\n"
        let bottom = NSRange(location: max(0, logView.text.count - 1), length: 1)
        logView.scrollRangeToVisible(bottom)
    }

    @objc private func startPairing() {
        environment.pairing.start()
    }

    @objc private func editSDKToken() {
        let alert = UIAlertController(
            title: "Personal Muse SDK token",
            message: "Stored only in this device's Keychain. Never committed or logged.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "mgst_…"
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.isSecureTextEntry = true
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let token = alert?.textFields?.first?.text else { return }
            do {
                try self.environment.pairing.saveSDKToken(token)
                self.refreshTokenUI()
            } catch {
                self.presentError(error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    @objc private func pasteSDKToken() {
        guard let token = UIPasteboard.general.string else {
            presentError("The clipboard is empty. Copy your Muse SDK token, then try again.")
            return
        }
        do {
            try environment.pairing.saveSDKToken(token)
            refreshTokenUI()
            appendLog("SDK token saved from clipboard")
        } catch {
            presentError("The clipboard does not contain a valid Muse SDK token.")
        }
    }

    @objc private func openTokenWebsite() {
        guard let url = URL(string: "https://gadgets.muse.ai/settings/sdk-tokens") else { return }
        UIApplication.shared.open(url)
    }

    private func refreshTokenUI() {
        let hasToken = environment.credentialStore.loadSDKToken()?.isEmpty == false
        tokenStatusLabel.text = hasToken
            ? "Token saved securely on this device"
            : "Required for community pairing"
        tokenStatusLabel.textColor = hasToken ? .systemGreen : .systemOrange
        pasteTokenButton.configuration?.title = hasToken
            ? "Replace from clipboard"
            : "Paste token from clipboard"
        tokenButton.configuration?.title = "Enter manually instead"
        pairButton.isEnabled = hasToken
#if targetEnvironment(simulator)
        pairButton.isEnabled = false
#endif
    }

    @objc private func showPermissions() {
        navigationController?.pushViewController(
            PermissionsViewController(center: environment.permissions),
            animated: true
        )
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Could not save", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
