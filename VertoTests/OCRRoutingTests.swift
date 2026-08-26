//
//  Copyright 2026 Yspritan
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import CoreGraphics
import XCTest
@testable import Verto

final class OCRRoutingPolicyTests: XCTestCase {
    func testDeviceBoundariesAndUnknownIdentifiers() {
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhone11,8").deviceGroup, .visionOnly)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhone12,1").deviceGroup, .visionOnly)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhone13,4").deviceGroup, .a14ThroughA16)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhone15,5").deviceGroup, .a14ThroughA16)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhone16,1").deviceGroup, .a17OrNewer)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhone20,1").deviceGroup, .a17OrNewer)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPad16,1").deviceGroup, .visionOnly)
        XCTAssertEqual(OCRRoutingPolicy(machineIdentifier: "iPhoneUnknown").deviceGroup, .visionOnly)
    }

    func testProductionModelOrderAndLanguageFiltering() throws {
        let balanced = OCRRoutingPolicy(deviceGroup: .a14ThroughA16)
        XCTAssertEqual(balanced.candidates(for: .english), [.model(.small), .model(.tiny), .vision])
        XCTAssertEqual(balanced.candidates(for: .japanese), [.model(.small), .vision])
        let korean = try XCTUnwrap(Language.all.first { $0.code == "ko" })
        XCTAssertEqual(balanced.candidates(for: korean), [.vision])

        let modern = OCRRoutingPolicy(deviceGroup: .a17OrNewer)
        XCTAssertEqual(modern.candidates(for: .english), [.model(.medium), .model(.small), .vision])
        XCTAssertEqual(modern.candidates(for: nil), [.model(.medium), .model(.small), .vision])
        XCTAssertEqual(
            modern.candidates(for: .english, testSelection: .tiny),
            [.model(.tiny), .vision]
        )
        XCTAssertEqual(modern.candidates(for: .english, testSelection: .vision), [.vision])
    }
}

final class ImageLanguageAssessmentTests: XCTestCase {
    func testConfidentSupportedScriptsUseModel() {
        XCTAssertEqual(
            ImageLanguageAssessment.decide(
                text: "Welcome to Toronto",
                hypotheses: ["en": 0.91, "de": 0.04]
            ),
            .model(.english)
        )
        XCTAssertEqual(
            ImageLanguageAssessment.decide(
                text: "メニュー",
                hypotheses: ["ja": 0.97]
            ),
            .model(.japanese)
        )
    }

    func testLowConfidenceAndUnsupportedOrMixedScriptsUseVision() {
        XCTAssertEqual(
            ImageLanguageAssessment.decide(
                text: "Menu", hypotheses: ["en": 0.51, "fr": 0.43]
            ),
            .vision
        )
        XCTAssertEqual(
            ImageLanguageAssessment.decide(
                text: "Welcome 환영", hypotheses: ["en": 0.92]
            ),
            .vision
        )
        XCTAssertEqual(
            ImageLanguageAssessment.decide(
                text: "Добро пожаловать", hypotheses: ["en": 0.90]
            ),
            .vision
        )
        XCTAssertEqual(
            ImageLanguageAssessment.decide(text: "123 — 456", hypotheses: ["en": 0.99]),
            .vision
        )
    }
}

final class RoutingTextRecognitionServiceTests: XCTestCase {
    func testFailureFallsThroughModelsThenVision() async throws {
        let primary = StubTextRecognizer(outcome: .failure)
        let fallback = StubTextRecognizer(outcome: .success("fallback"))
        let vision = StubTextRecognizer(outcome: .success("vision"))
        let service = RoutingTextRecognitionService(
            models: [
                .init(tier: .medium, service: primary),
                .init(tier: .small, service: fallback),
            ],
            system: vision,
            languageScout: StubLanguageScout(decision: .model(.english))
        )

        let result = try await service.recognizeText(in: Self.image, languages: [.english])

        XCTAssertEqual(result.map(\.text), ["fallback"])
        let primaryCalls = await primary.callCount
        let fallbackCalls = await fallback.callCount
        let visionCalls = await vision.callCount
        XCTAssertEqual(primaryCalls, 1)
        XCTAssertEqual(fallbackCalls, 1)
        XCTAssertEqual(visionCalls, 0)
    }

    func testAutoScoutRejectsUnsupportedLanguageBeforeModel() async throws {
        let model = StubTextRecognizer(outcome: .success("model"))
        let vision = StubTextRecognizer(outcome: .success("vision"))
        let korean = try XCTUnwrap(Language.all.first { $0.code == "ko" })
        let service = RoutingTextRecognitionService(
            models: [.init(tier: .medium, service: model)],
            system: vision,
            languageScout: StubLanguageScout(decision: .model(korean))
        )

        let result = try await service.recognizeText(in: Self.image, languages: [])

        XCTAssertEqual(result.map(\.text), ["vision"])
        let modelCalls = await model.callCount
        let visionCalls = await vision.callCount
        XCTAssertEqual(modelCalls, 0)
        XCTAssertEqual(visionCalls, 1)
    }

    func testNoTextIsAConclusionAndDoesNotRunBackup() async {
        let primary = StubTextRecognizer(outcome: .noText)
        let fallback = StubTextRecognizer(outcome: .success("fallback"))
        let service = RoutingTextRecognitionService(
            models: [
                .init(tier: .medium, service: primary),
                .init(tier: .small, service: fallback),
            ],
            system: fallback,
            languageScout: StubLanguageScout(decision: .model(.english))
        )

        do {
            _ = try await service.recognizeText(in: Self.image, languages: [.english])
            XCTFail("Expected noTextFound")
        } catch {
            XCTAssertEqual(error as? TextRecognitionError, .noTextFound)
        }
        let fallbackCalls = await fallback.callCount
        XCTAssertEqual(fallbackCalls, 0)
    }

    private static let image: CGImage = {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()
}

@MainActor
final class OCRModelCatalogTests: XCTestCase {
    func testLaunchInstallsSequentialRouteThenRemovesUnroutedModel() async {
        let installer = RecordingOCRInstaller(installed: [.medium])
        let catalog = OCRModelCatalog(
            installer: installer,
            policy: OCRRoutingPolicy(deviceGroup: .a14ThroughA16),
            modelHealthCheck: { _ in true }
        )

        await catalog.prepareAutomaticModelsIfNeeded()?.value

        XCTAssertEqual(installer.events, ["install:small", "install:tiny", "remove:medium"])
        XCTAssertEqual(catalog.state(of: .small), .installed)
        XCTAssertEqual(catalog.state(of: .tiny), .installed)
    }

    func testFailedFallbackDoesNotCleanOldModelAndRetriesNextColdLaunch() async {
        let installer = RecordingOCRInstaller(installed: [.medium], failing: [.tiny])
        let firstLaunch = OCRModelCatalog(
            installer: installer,
            policy: OCRRoutingPolicy(deviceGroup: .a14ThroughA16),
            modelHealthCheck: { _ in true }
        )
        await firstLaunch.prepareAutomaticModelsIfNeeded()?.value
        XCTAssertTrue(installer.isInstalled(.medium))
        XCTAssertEqual(firstLaunch.state(of: .tiny), .failed(.network))

        installer.failing = []
        let nextLaunch = OCRModelCatalog(
            installer: installer,
            policy: OCRRoutingPolicy(deviceGroup: .a14ThroughA16),
            modelHealthCheck: { _ in true }
        )
        await nextLaunch.prepareAutomaticModelsIfNeeded()?.value

        XCTAssertTrue(installer.isInstalled(.tiny))
        XCTAssertFalse(installer.isInstalled(.medium))
    }

    func testVisionOnlyRemovesAllLegacyModelsWithoutDownloading() async {
        let installer = RecordingOCRInstaller(installed: [.tiny, .small, .medium])
        let catalog = OCRModelCatalog(
            installer: installer,
            policy: OCRRoutingPolicy(deviceGroup: .visionOnly),
            modelHealthCheck: { _ in true }
        )

        await catalog.prepareAutomaticModelsIfNeeded()?.value

        XCTAssertEqual(installer.events, ["remove:tiny", "remove:small", "remove:medium"])
        XCTAssertEqual(catalog.effectiveEngine(for: .english), .vision)
    }

    func testUnhealthyRoutedModelPreventsLegacyCleanup() async {
        let installer = RecordingOCRInstaller(installed: [.tiny, .small, .medium])
        let catalog = OCRModelCatalog(
            installer: installer,
            policy: OCRRoutingPolicy(deviceGroup: .a14ThroughA16),
            modelHealthCheck: { $0.tier != .small }
        )

        await catalog.prepareAutomaticModelsIfNeeded()?.value

        XCTAssertTrue(installer.isInstalled(.medium))
        XCTAssertEqual(catalog.effectiveEngine(for: .english), .model(.tiny))
    }
}

private struct StubLanguageScout: ImageLanguageScouting {
    let decision: ImageLanguageScoutDecision
    func decideEngine(for image: CGImage) async -> ImageLanguageScoutDecision { decision }
}

private actor StubTextRecognizer: TextRecognitionService {
    enum Outcome: Sendable {
        case success(String)
        case failure
        case noText
    }

    let outcome: Outcome
    private(set) var callCount = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func recognizeText(
        in image: CGImage,
        languages: [Language]
    ) async throws -> [RecognizedTextBlock] {
        callCount += 1
        switch outcome {
        case .success(let text):
            let quad = TextQuad(
                topLeft: CGPoint(x: 0, y: 1),
                topRight: CGPoint(x: 1, y: 1),
                bottomRight: CGPoint(x: 1, y: 0),
                bottomLeft: CGPoint(x: 0, y: 0)
            )
            return [RecognizedTextBlock(text: text, quad: quad)]
        case .failure: throw TextRecognitionError.recognitionFailed
        case .noText: throw TextRecognitionError.noTextFound
        }
    }
}

private final class RecordingOCRInstaller: OCRModelPackInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var installedTiers: Set<OCRModelTier>
    private var recordedEvents: [String] = []
    var failing: Set<OCRModelTier>

    init(installed: Set<OCRModelTier> = [], failing: Set<OCRModelTier> = []) {
        installedTiers = installed
        self.failing = failing
    }

    var events: [String] { lock.withLock { recordedEvents } }

    func isInstalled(_ tier: OCRModelTier) -> Bool {
        lock.withLock { installedTiers.contains(tier) }
    }

    func install(
        _ tier: OCRModelTier,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledOCRModel {
        lock.withLock { recordedEvents.append("install:\(tier.rawValue)") }
        if lock.withLock({ failing.contains(tier) }) { throw OCRModelInstallError.network }
        onProgress(1)
        _ = lock.withLock { installedTiers.insert(tier) }
        return model(for: tier)
    }

    func installed(_ tier: OCRModelTier) -> InstalledOCRModel? {
        lock.withLock { installedTiers.contains(tier) } ? model(for: tier) : nil
    }

    func remove(_ tier: OCRModelTier) throws {
        lock.withLock {
            recordedEvents.append("remove:\(tier.rawValue)")
            installedTiers.remove(tier)
        }
    }

    func diskUsage(_ tier: OCRModelTier) -> Int64 { isInstalled(tier) ? 1 : 0 }

    private func model(for tier: OCRModelTier) -> InstalledOCRModel {
        let root = URL(fileURLWithPath: "/private/tmp/ocr-routing-tests/\(tier.rawValue)")
        return InstalledOCRModel(
            tier: tier,
            detectorURL: root.appendingPathComponent("detector.mlmodelc"),
            recognizerURL: root.appendingPathComponent("recognizer.mlmodelc"),
            charactersURL: root.appendingPathComponent("charset.txt")
        )
    }
}
