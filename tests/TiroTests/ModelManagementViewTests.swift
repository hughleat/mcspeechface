import AppKit
import Testing
@testable import Tiro

@Suite(.serialized)
struct ModelManagementViewTests {
    @Test @MainActor
    func serviceRefusesToDeleteSelectedModel() async {
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        DictationModel.select(.coreMLCompact)

        let service = TiroService()
        service.startDelete(key: DictationModel.coreMLCompactKey)

        #expect(
            service.modelOperationError(for: DictationModel.coreMLCompactKey)
                == "Select another transcription model before deleting this one."
        )
    }

    @Test @MainActor
    func staleActivationCannotOverwriteNewerSelection() async throws {
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        let service = TiroService()
        try service.select(model: available[0])
        try service.select(model: available[1])

        try await service.activate(model: available[0])

        #expect(DictationModel.selected.key == available[1].key)
    }

    @Test @MainActor
    func changingTableSelectionDoesNotReenterItsDelegate() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }

        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        DictationModel.select(available[0])

        let view = ModelManagementView(service: TiroService())
        var changedModels: [String] = []
        view.onModelChanged = { changedModels.append($0.key) }
        view.apply(available.map { managedModel($0) })
        let table = try #require(firstSubview(of: NSTableView.self, in: view))

        table.selectRowIndexes(
            IndexSet(integer: 1),
            byExtendingSelection: false
        )

        #expect(DictationModel.selected.key == available[1].key)
        #expect(changedModels == [available[1].key])
        #expect(table.selectedRow == 1)
        view.cancelWork()
    }

    @Test @MainActor
    func unavailableModelCannotAcquireTheSelectionHighlight() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        DictationModel.select(available[0])

        let view = ModelManagementView(service: TiroService())
        view.apply([
            managedModel(available[0]),
            managedModel(available[1], installed: false, usable: false),
        ])
        let table = try #require(firstSubview(of: NSTableView.self, in: view))

        #expect((table.delegate as AnyObject?) === view)
        #expect(table.delegate?.tableView?(table, shouldSelectRow: 0) == true)
        #expect(table.delegate?.tableView?(table, shouldSelectRow: 1) == false)
        #expect(table.selectedRow == 0)
        view.cancelWork()
    }

    @Test @MainActor
    func selectionEligibilityCoversUnavailableAndBusyStates() {
        let downloadable = DictationModel.coreMLCompact
        let appleSpeech = DictationModel.appleSpeech

        #expect(ModelManagementView.allowsSelection(
            of: managedModel(downloadable),
            modelUseInProgress: false,
            modelOperationInProgress: false
        ))
        #expect(!ModelManagementView.allowsSelection(
            of: managedModel(downloadable, installed: false, usable: false),
            modelUseInProgress: false,
            modelOperationInProgress: false
        ))
        #expect(ModelManagementView.allowsSelection(
            of: managedModel(appleSpeech, usable: false),
            modelUseInProgress: false,
            modelOperationInProgress: false
        ))
        #expect(!ModelManagementView.allowsSelection(
            of: managedModel(appleSpeech, installed: false, usable: false),
            modelUseInProgress: false,
            modelOperationInProgress: false
        ))
        #expect(!ModelManagementView.allowsSelection(
            of: managedModel(downloadable, operation: .downloading(progress: 0.2)),
            modelUseInProgress: false,
            modelOperationInProgress: true
        ))
        #expect(!ModelManagementView.allowsSelection(
            of: managedModel(downloadable),
            modelUseInProgress: false,
            modelOperationInProgress: true
        ))
        #expect(!ModelManagementView.allowsSelection(
            of: managedModel(downloadable),
            modelUseInProgress: true,
            modelOperationInProgress: false
        ))
    }

    @Test @MainActor
    func deletingSelectionFallsBackWithoutReenteringDelegate() {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: "selectedModel")
        defer {
            restoreSelection(previousSelection, in: defaults)
        }
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        DictationModel.select(available[0])

        let view = ModelManagementView(service: TiroService())
        var changedModels: [String] = []
        view.onModelChanged = { changedModels.append($0.key) }
        view.apply(available.map { managedModel($0) })
        changedModels.removeAll()

        view.apply([
            managedModel(available[0], usable: false, deleting: true),
            managedModel(available[1]),
        ])

        #expect(DictationModel.selected.key == available[1].key)
        #expect(changedModels == [available[1].key])
        view.cancelWork()
    }

    @Test @MainActor
    func downloadProgressDoesNotRebuildModelInventoryConsumers() {
        _ = NSApplication.shared
        let model = DictationModel.all.first { $0.downloadSizeBytes != nil }!
        let view = ModelManagementView(service: TiroService())
        var inventoryUpdates = 0
        view.onModelsChanged = { _ in inventoryUpdates += 1 }

        view.apply([managedModel(model, operation: .downloading(progress: 0.1))])
        view.apply([managedModel(model, operation: .downloading(progress: 0.2))])

        #expect(inventoryUpdates == 1)
        view.cancelWork()
    }

    @Test @MainActor
    func comparisonActionRemainsDiscoverableWithOneModel() throws {
        _ = NSApplication.shared
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        let view = ModelManagementView(service: TiroService())
        let button = try #require(allSubviews(of: NSButton.self, in: view).first {
            $0.title == "Compare Installed Models…"
        })
        var comparisonRequests = 0
        view.onCompareModels = { comparisonRequests += 1 }

        view.apply([managedModel(available[0])])
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(comparisonRequests == 1)
        view.cancelWork()
    }

    @Test @MainActor
    func globalOperationStateRefreshesEveryRow() {
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        let previous = available.map { managedModel($0, usable: false) }
        let updated = [
            managedModel(available[0], usable: false, operation: .downloading(progress: 0.1)),
            managedModel(available[1], usable: false),
        ]

        #expect(
            ModelManagementView.rowsRequiringReload(from: previous, to: updated)
                == IndexSet(updated.indices)
        )
    }

    @Test @MainActor
    func progressUpdatePreservesSelection() throws {
        _ = NSApplication.shared
        let available = Array(
            DictationModel.all.filter { $0.downloadSizeBytes != nil }.prefix(2)
        )
        #expect(available.count == 2)
        guard available.count == 2 else { return }
        DictationModel.select(available[0])
        let view = ModelManagementView(service: TiroService())
        view.apply(available.map { managedModel($0) })
        let table = try #require(firstSubview(of: NSTableView.self, in: view))

        view.apply([
            managedModel(available[0], operation: .downloading(progress: 0.2)),
            managedModel(available[1]),
        ])

        #expect(table.selectedRow == 0)
        view.cancelWork()
    }

    private func restoreSelection(
        _ selection: String?,
        in defaults: UserDefaults
    ) {
        if let selection {
            defaults.set(selection, forKey: "selectedModel")
        } else {
            defaults.removeObject(forKey: "selectedModel")
        }
    }

    @MainActor
    private func managedModel(
        _ model: DictationModel,
        installed: Bool = true,
        usable: Bool = true,
        deleting: Bool = false,
        operation: ManagedModelOperation? = nil
    ) -> ManagedModel {
        ManagedModel(
            key: model.key,
            installedSizeBytes: 1,
            installed: installed,
            usable: usable,
            operation: deleting ? .deleting : operation,
            loaded: false,
            operationError: nil,
            downloadSpace: nil,
            state: "ready"
        )
    }

    @MainActor
    private func firstSubview<T: NSView>(
        of type: T.Type,
        in view: NSView
    ) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap {
            firstSubview(of: type, in: $0)
        }.first
    }

    @MainActor
    private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.compactMap { $0 as? T }
            + view.subviews.flatMap { allSubviews(of: type, in: $0) }
    }

}
