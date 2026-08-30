import Foundation
import Testing
@testable import McSpeechface

struct DictationModelCatalogTests {
    @Test
    func catalogContainsNativeAndSystemModelsWithStableKeys() {
        #expect(DictationModel.catalog.map(\.key) == [
            "apple-speech",
            "coreml-compact",
            "coreml-parakeet-v2",
            "coreml-parakeet-v3",
            "coreml-parakeet-unified",
            "coreml-whisper-tiny-english",
            "coreml-whisper-base-english",
            "coreml-whisper-small-english",
            "coreml-whisper-tiny",
            "coreml-whisper-base",
            "coreml-whisper-small",
            "coreml-whisper-distil-large-v3",
            "coreml-whisper-distil-large-v3-turbo",
            "coreml-whisper-large-v3",
            "coreml-whisper-turbo",
        ])
        #expect(DictationModel.appleSpeech.provisioning == .systemManaged)
        #expect(DictationModel.appleSpeech.downloadSizeBytes == nil)
        #expect(DictationModel.catalog.dropFirst().allSatisfy {
            ($0.downloadSizeBytes ?? 0) > 0
        })
        #expect(!DictationModel.appleSpeech.supportsSpeakerIdentification)
        #expect(
            !DictationModel.catalog.first {
                $0.key == DictationModel.coreMLParakeetUnifiedKey
            }!.supportsSpeakerIdentification
        )
        #expect(DictationModel.coreMLCompact.supportsSpeakerIdentification)
    }

    @Test
    func modelFamiliesExposeTheirActualLanguageControls() {
        let support = Dictionary(uniqueKeysWithValues: DictationModel.catalog.map {
            ($0.key, $0.languageSupport)
        })
        #expect(support["apple-speech"] == .selectable)
        #expect(support["coreml-parakeet-v3"] == .automatic)

        let englishModels = [
            "coreml-compact", "coreml-parakeet-v2", "coreml-parakeet-unified",
            "coreml-whisper-tiny-english", "coreml-whisper-base-english",
            "coreml-whisper-small-english", "coreml-whisper-distil-large-v3",
            "coreml-whisper-distil-large-v3-turbo",
        ]
        #expect(englishModels.allSatisfy { support[$0] == .english })

        let multilingualWhisperModels = [
            "coreml-whisper-tiny", "coreml-whisper-base", "coreml-whisper-small",
            "coreml-whisper-large-v3", "coreml-whisper-turbo",
        ]
        #expect(multilingualWhisperModels.allSatisfy { support[$0] == .selectable })
    }

    @Test
    func whisperLanguagesUseExpectedCodes() {
        #expect(DictationLanguage.auto.whisperCode == nil)
        #expect(DictationLanguage.english.whisperCode == "en")
        #expect(DictationLanguage.cantonese.whisperCode == "yue")
        #expect(DictationLanguage.chinese.whisperCode == "zh")
        #expect(DictationLanguage.filipino.whisperCode == "tl")
        #expect(DictationLanguage.english.appleLocaleIdentifier.hasPrefix("en"))
    }

    @Test
    func storedModelKeysHaveReadableDisplayNames() {
        #expect(
            DictationModel.displayName(forStoredKey: "coreml-parakeet-v3")
                == "Parakeet 0.6B v3"
        )
        #expect(
            DictationModel.displayName(forStoredKey: "legacy/vendor-model")
                == "vendor-model"
        )
    }
}
