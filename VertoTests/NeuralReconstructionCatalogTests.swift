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

import CoreML
import XCTest
@testable import Verto

final class NeuralReconstructionCatalogTests: XCTestCase {
    func testEligibilityRejectsEveryUnsupportedDeviceBoundary() {
        let eligible = deviceFacts()
        XCTAssertNil(NeuralReconstructionEligibility.reason(for: eligible))
        XCTAssertEqual(
            NeuralReconstructionEligibility.reason(for: deviceFacts(isSimulator: true)),
            .simulator
        )
        XCTAssertEqual(
            NeuralReconstructionEligibility.reason(for: deviceFacts(isPhone: false)),
            .notPhone
        )
        XCTAssertEqual(
            NeuralReconstructionEligibility.reason(for: deviceFacts(supportsApple7: false)),
            .metalFamily
        )
        XCTAssertEqual(
            NeuralReconstructionEligibility.reason(for: deviceFacts(identifier: nil)),
            .missingDeviceIdentity
        )
    }

    func testReleaseGateHasNoDownloadDescriptor() {
        XCTAssertNil(NeuralReconstructionRelease.published)
    }

    func testModelTreeHashChangesWithModelAndIgnoresProbeSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neural-tree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("weights.bin")
        try Data("first".utf8).write(to: model)

        let original = try NeuralReconstructionModelTreeHasher.sha256(of: root)
        try Data("sidecar changes freely".utf8).write(
            to: root.appendingPathComponent(NeuralReconstructionProbeSidecar.fileName)
        )
        XCTAssertEqual(try NeuralReconstructionModelTreeHasher.sha256(of: root), original)

        try Data("second".utf8).write(to: model)
        XCTAssertNotEqual(try NeuralReconstructionModelTreeHasher.sha256(of: root), original)
    }

    func testSidecarRoundTripsRawFactsAtomically() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("neural-sidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = NeuralReconstructionProbeSidecarStore(modelDirectory: root)
        let sidecar = completedSidecar(recordedAt: Date(timeIntervalSince1970: 1_700_000_000))

        try store.save(sidecar)

        XCTAssertEqual(store.load(), sidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.url.path))
    }

    func testEvaluationUsesParityThresholdsWithoutCalendarExpiry() {
        let veryOld = Date(timeIntervalSince1970: 1)
        let accepted = completedSidecar(recordedAt: veryOld)
        XCTAssertEqual(
            NeuralReconstructionProbeEvaluation.evaluate(accepted, now: Date()),
            .ready(.all)
        )

        var output = [Float](repeating: 0, count: 100)
        output[0] = 0.051
        output[1] = 0.051
        let rejectedParity = NeuralReconstructionProbeMath.parity(
            [Float](repeating: 0, count: 100),
            output
        )
        let rejected = completedSidecar(recordedAt: veryOld, parity: rejectedParity)
        XCTAssertEqual(
            NeuralReconstructionProbeEvaluation.evaluate(rejected, now: Date()),
            .ready(.cpuAndGPU)
        )
    }

    func testAllFailureCanUseFastCPUAndGPUFallback() {
        let sidecar = completedSidecar(
            all: NeuralReconstructionProbeBackendFacts(
                route: .all,
                warmupCompleted: false,
                timingSeconds: [],
                errorDescription: "ANE unavailable"
            ),
            cpuAndGPU: NeuralReconstructionProbeBackendFacts(
                route: .cpuAndGPU,
                warmupCompleted: true,
                timingSeconds: [0.9, 0.8, 1.0],
                errorDescription: nil
            ),
            parity: nil
        )
        XCTAssertEqual(
            NeuralReconstructionProbeEvaluation.evaluate(sidecar, now: Date()),
            .ready(.cpuAndGPU)
        )
    }

    func testTransientFailureKeepsPersistentBackoff() {
        let retryAfter = Date(timeIntervalSince1970: 2_000_000_000)
        let sidecar = NeuralReconstructionProbeSidecar(
            schemaVersion: 1,
            key: probeKey(),
            recordedAt: Date(timeIntervalSince1970: 1_900_000_000),
            attemptNumber: 3,
            status: .transientFailure,
            all: nil,
            cpuAndGPU: nil,
            parity: nil,
            errorDescription: "busy",
            retryAfter: retryAfter
        )
        XCTAssertEqual(
            NeuralReconstructionProbeEvaluation.evaluate(
                sidecar,
                now: Date(timeIntervalSince1970: 1_950_000_000)
            ),
            .retry(retryAfter)
        )
    }

    func testProbeUsesOneWarmupAndThreeTimingsPerBackendWithSameFixture() async throws {
        let recorder = ProbeCallRecorder()
        let fixture = NeuralReconstructionProbeFixture(
            width: 1,
            height: 1,
            rgbBytes: Data([10, 20, 30]),
            knownMaskBytes: Data([0])
        )
        let facts = try await NeuralReconstructionCatalog.runProbe(
            modelURL: URL(fileURLWithPath: "/private/tmp/model.mlmodelc"),
            fixture: fixture
        ) { _, units, receivedFixture in
            await recorder.record(units: units, fixture: receivedFixture)
        }

        let calls = await recorder.snapshot()
        XCTAssertEqual(calls.allCount, 4)
        XCTAssertEqual(calls.cpuAndGPUCount, 4)
        XCTAssertEqual(calls.fixtures, [fixture])
        XCTAssertTrue(facts.all.warmupCompleted)
        XCTAssertEqual(facts.all.timingSeconds.count, 3)
        XCTAssertTrue(facts.cpuAndGPU.warmupCompleted)
        XCTAssertEqual(facts.cpuAndGPU.timingSeconds.count, 3)
        XCTAssertEqual(facts.parity?.comparedValueCount, 3)
        XCTAssertEqual(facts.parity?.meanAbsoluteError ?? 1, 0.005, accuracy: 0.000_001)
    }

    private func deviceFacts(
        isSimulator: Bool = false,
        isPhone: Bool = true,
        supportsApple7: Bool = true,
        identifier: String? = "IFV"
    ) -> NeuralReconstructionDeviceFacts {
        NeuralReconstructionDeviceFacts(
            isSimulator: isSimulator,
            isPhone: isPhone,
            supportsApple7: supportsApple7,
            identifierForVendor: identifier,
            machine: "iPhone13,2",
            kernelOSVersion: "23A344"
        )
    }

    private func probeKey() -> NeuralReconstructionProbeKey {
        NeuralReconstructionProbeKey(
            identifierForVendor: "IFV",
            machine: "iPhone13,2",
            kernelOSVersion: "23A344",
            modelTreeSHA256: String(repeating: "a", count: 64),
            sidecarSchemaVersion: 1,
            fixtureSchemaVersion: 1,
            fixtureVersion: "fixture-1"
        )
    }

    private func completedSidecar(
        recordedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        all: NeuralReconstructionProbeBackendFacts = NeuralReconstructionProbeBackendFacts(
            route: .all,
            warmupCompleted: true,
            timingSeconds: [0.7, 0.8, 0.9],
            errorDescription: nil
        ),
        cpuAndGPU: NeuralReconstructionProbeBackendFacts = NeuralReconstructionProbeBackendFacts(
            route: .cpuAndGPU,
            warmupCompleted: true,
            timingSeconds: [0.7, 0.8, 0.9],
            errorDescription: nil
        ),
        parity: NeuralReconstructionProbeParityFacts? = NeuralReconstructionProbeParityFacts(
            meanAbsoluteError: 0.005,
            fractionAbovePointZeroFive: 0.01,
            comparedValueCount: 100
        )
    ) -> NeuralReconstructionProbeSidecar {
        NeuralReconstructionProbeSidecar(
            schemaVersion: 1,
            key: probeKey(),
            recordedAt: recordedAt,
            attemptNumber: 1,
            status: .completed,
            all: all,
            cpuAndGPU: cpuAndGPU,
            parity: parity,
            errorDescription: nil,
            retryAfter: nil
        )
    }
}

private actor ProbeCallRecorder {
    private var allCount = 0
    private var cpuAndGPUCount = 0
    private var fixtures: [NeuralReconstructionProbeFixture] = []

    func record(
        units: MLComputeUnits,
        fixture: NeuralReconstructionProbeFixture
    ) -> NeuralReconstructionProbeSample {
        fixtures.append(fixture)
        switch units {
        case .all:
            allCount += 1
            return NeuralReconstructionProbeSample(output: [0, 0, 0])
        case .cpuAndGPU:
            cpuAndGPUCount += 1
            return NeuralReconstructionProbeSample(output: [0.015, 0, 0])
        case .cpuOnly, .cpuAndNeuralEngine:
            return NeuralReconstructionProbeSample(output: [])
        @unknown default:
            return NeuralReconstructionProbeSample(output: [])
        }
    }

    func snapshot() -> (
        allCount: Int,
        cpuAndGPUCount: Int,
        fixtures: [NeuralReconstructionProbeFixture]
    ) {
        (allCount, cpuAndGPUCount, Array(Set(fixtures)))
    }
}
