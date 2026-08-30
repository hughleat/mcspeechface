import Testing
@testable import McSpeechface

struct SetupReadinessTests {
    @Test
    func setupRequiresBothPermissionsAndTheSelectedModel() {
        let ready = SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: true,
            selectedModelKey: "compact",
            usableModelKeys: ["compact"]
        )
        #expect(ready.canFinish)

        #expect(!SetupReadiness(
            microphoneAllowed: false,
            accessibilityAllowed: true,
            selectedModelKey: "compact",
            usableModelKeys: ["compact"]
        ).canFinish)
        #expect(!SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: false,
            selectedModelKey: "compact",
            usableModelKeys: ["compact"]
        ).canFinish)
        #expect(!SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: true,
            selectedModelKey: "compact",
            usableModelKeys: []
        ).canFinish)
        #expect(!SetupReadiness(
            microphoneAllowed: true,
            accessibilityAllowed: true,
            selectedModelKey: "multilingual",
            usableModelKeys: ["compact"]
        ).canFinish)
    }

    @Test
    func modelInventoryDoesNotTreatLoadingOrFailureAsMissing() {
        #expect(ModelInventoryStatus.loading != .missing)
        #expect(ModelInventoryStatus.unavailable != .missing)
        #expect(ModelInventoryStatus.available != .missing)
        #expect(ModelInventoryStatus.missing == .missing)
        #expect(ModelInventoryStatus.loading.afterPreparationFailure == .unavailable)
        #expect(ModelInventoryStatus.available.afterPreparationFailure == .available)
    }

    @Test
    func modelPreparationIsSingleFlightAndKeepsInventoryLoading() {
        var preparation = ModelPreparationState()

        let firstStart = preparation.begin()
        let overlappingStart = preparation.begin()
        #expect(firstStart)
        #expect(!overlappingStart)
        #expect(preparation.inventoryStatus(hasSelectedModel: true) == .loading)
        #expect(preparation.inventoryStatus(hasSelectedModel: false) == .missing)

        preparation.finish()
        #expect(preparation.inventoryStatus(hasSelectedModel: true) == .available)
        let restarted = preparation.begin()
        #expect(restarted)
    }
}
