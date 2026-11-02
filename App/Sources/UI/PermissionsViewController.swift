import UIKit

final class PermissionsViewController: UITableViewController {
    private let center: PermissionCenter
    private let permissions = AppPermission.allCases

    init(center: PermissionCenter) {
        self.center = center
        super.init(style: .insetGrouped)
        title = "Permissions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Permission")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        permissions.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let permission = permissions[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "Permission", for: indexPath)
        let statusText = center.status(for: permission).rawValue
        cell.textLabel?.text = permission.title
        cell.detailTextLabel?.text = statusText
        cell.accessoryType = .disclosureIndicator
        if #available(iOS 14.0, *) {
            var content = cell.defaultContentConfiguration()
            content.text = permission.title
            content.secondaryText = statusText
            cell.contentConfiguration = content
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let permission = permissions[indexPath.row]
        center.request(permission) { [weak self] _ in
            self?.tableView.reloadRows(at: [indexPath], with: .automatic)
        }
        tableView.deselectRow(at: indexPath, animated: true)
    }
}

