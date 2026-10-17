import CarPlay
import UIKit
import PullUpDomain
import PullUpFeatures

/// CarPlay "Driving Task" scene: start a drive for a garage vehicle and see
/// glanceable status. Driving Task apps may only use list, grid,
/// information, point-of-interest, alert and action-sheet templates, and
/// Apple asks them to keep the screen simple, so there's no speedometer here.
///
/// This code builds and runs in the CarPlay simulator, but the app only
/// appears on real head units once Apple grants the
/// com.apple.developer.carplay-driving-task entitlement (docs/CARPLAY.md).
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var statusTemplate: CPInformationTemplate?
    private var refreshTask: Task<Void, Never>?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let status = CPInformationTemplate(title: "Pull Up", layout: .leading, items: [], actions: [])
        statusTemplate = status
        refresh()
        interfaceController.setRootTemplate(status, animated: false, completion: nil)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refresh()
            }
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        refreshTask?.cancel()
        refreshTask = nil
        self.interfaceController = nil
        statusTemplate = nil
    }

    private func refresh() {
        guard let statusTemplate, let app = AppModel.shared else { return }
        let status = DriveStatus(recorder: app.recorder, unit: app.themeStore.theme.unit)
        statusTemplate.items = status.lines.map { CPInformationItem(title: $0.title, detail: $0.detail) }
        if app.userID == nil {
            statusTemplate.actions = []
            statusTemplate.items = [CPInformationItem(title: "Signed out", detail: "Open Pull Up on your iPhone to sign in.")]
        } else if status.isRecording {
            statusTemplate.actions = [CPTextButton(title: "Stop and save", textStyle: .confirm) { _ in
                Task { @MainActor in await app.recorder.finish() }
            }]
        } else {
            statusTemplate.actions = [CPTextButton(title: "Start drive", textStyle: .normal) { [weak self] _ in
                Task { @MainActor in self?.showVehicles() }
            }]
        }
    }

    private func showVehicles() {
        guard let app = AppModel.shared else { return }
        let vehicles = app.garage.active
        var items: [CPListItem] = vehicles.map { vehicle in
            let item = CPListItem(text: vehicle.displayName, detailText: "\(vehicle.year) \(vehicle.make) \(vehicle.model)")
            item.handler = { [weak self] _, completion in
                completion()
                Task { @MainActor in await self?.start(vehicle) }
            }
            return item
        }
        let guest = CPListItem(text: "Guest vehicle", detailText: "Not linked to a garage vehicle")
        guest.handler = { [weak self] _, completion in
            completion()
            Task { @MainActor in await self?.start(nil) }
        }
        items.append(guest)
        let list = CPListTemplate(title: "Choose vehicle", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func start(_ vehicle: Vehicle?) async {
        guard let app = AppModel.shared else { return }
        if let failure = await app.recorder.start(with: vehicle) {
            let alert = CPAlertTemplate(titleVariants: [failure.message], actions: [
                CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                    Task { @MainActor in self?.interfaceController?.dismissTemplate(animated: true, completion: nil) }
                },
            ])
            interfaceController?.presentTemplate(alert, animated: true, completion: nil)
        } else {
            interfaceController?.popToRootTemplate(animated: true, completion: nil)
        }
        refresh()
    }
}
