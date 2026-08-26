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

import Darwin
import Foundation

enum OCRRouteCandidate: Equatable, Sendable {
    case model(OCRModelTier)
    case vision
}

/// OCR Test 构建唯一的人工覆盖项。生产构建不传入持久化容器，因此永远是 `.automatic`。
enum OCRTestSelection: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case vision
    case tiny
    case small
    case medium

    var id: String { rawValue }

    var tier: OCRModelTier? { OCRModelTier(rawValue: rawValue) }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "自动")
        case .vision: "Vision"
        case .tiny: OCRModelTier.tiny.displayName
        case .small: OCRModelTier.small.displayName
        case .medium: OCRModelTier.medium.displayName
        }
    }
}

/// 唯一的设备→模型链规则。下载、推理和 OCR Test 角标都必须从这里取结果。
struct OCRRoutingPolicy: Equatable, Sendable {
    enum DeviceGroup: Equatable, Sendable {
        case visionOnly
        case a14ThroughA16
        case a17OrNewer
    }

    let deviceGroup: DeviceGroup

    init(machineIdentifier: String) {
        deviceGroup = Self.deviceGroup(for: machineIdentifier)
    }

    init(deviceGroup: DeviceGroup) {
        self.deviceGroup = deviceGroup
    }

    var automaticModelTiers: [OCRModelTier] {
        switch deviceGroup {
        case .visionOnly: []
        case .a14ThroughA16: [.small, .tiny]
        case .a17OrNewer: [.medium, .small]
        }
    }

    func candidates(
        for language: Language?,
        testSelection: OCRTestSelection = .automatic
    ) -> [OCRRouteCandidate] {
        let tiers: [OCRModelTier]
        switch testSelection {
        case .automatic:
            tiers = automaticModelTiers
        case .vision:
            tiers = []
        case .tiny, .small, .medium:
            tiers = testSelection.tier.map { [$0] } ?? []
        }
        let supported = language.map { language in
            tiers.filter { $0.recognizes(language) }
        } ?? tiers
        return supported.map(OCRRouteCandidate.model) + [.vision]
    }

    static func deviceGroup(for machineIdentifier: String) -> DeviceGroup {
        let parts = machineIdentifier.split(separator: ",", maxSplits: 1)
        guard parts.count == 2,
              parts[0].hasPrefix("iPhone"),
              let generation = Int(parts[0].dropFirst("iPhone".count)),
              Int(parts[1]) != nil else {
            // 未识别的代号不猜芯片能力：Vision 是系统自带且覆盖最宽的安全路径。
            return .visionOnly
        }
        switch generation {
        case ...12: return .visionOnly
        case 13...15: return .a14ThroughA16
        default: return .a17OrNewer
        }
    }
}

enum OCRHardwareIdentifier {
    static func current() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else {
            return "unknown"
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else {
            return "unknown"
        }
        return String(cString: bytes)
    }
}
