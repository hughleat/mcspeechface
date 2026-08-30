struct SetupReadiness: Equatable {
    let microphoneAllowed: Bool
    let accessibilityAllowed: Bool
    let selectedModelKey: String
    let usableModelKeys: Set<String>

    var selectedModelReady: Bool { usableModelKeys.contains(selectedModelKey) }

    var canFinish: Bool {
        microphoneAllowed && accessibilityAllowed && selectedModelReady
    }
}

enum ModelInventoryStatus: Equatable {
    case loading
    case available
    case missing
    case unavailable

    var afterPreparationFailure: ModelInventoryStatus {
        self == .available ? .available : .unavailable
    }
}

struct ModelPreparationState: Equatable {
    private(set) var isInProgress = false

    mutating func begin() -> Bool {
        guard !isInProgress else { return false }
        isInProgress = true
        return true
    }

    mutating func finish() {
        isInProgress = false
    }

    func inventoryStatus(hasSelectedModel: Bool) -> ModelInventoryStatus {
        guard hasSelectedModel else { return .missing }
        return isInProgress ? .loading : .available
    }
}
