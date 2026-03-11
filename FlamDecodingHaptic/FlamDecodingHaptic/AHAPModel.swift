//
//  AHAPModel.swift
//  FlamDecodingHaptic
//

import Foundation

struct AHAPPattern: Codable {
    let version: Int
    let pattern: [AHAPEventWrapper]

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case pattern = "Pattern"
    }
}

struct AHAPEventWrapper: Codable {
    let event: AHAPEvent?

    enum CodingKeys: String, CodingKey {
        case event = "Event"
    }
}

struct AHAPEvent: Codable {
    let time: Double
    let eventType: String
    let eventDuration: Double?
    let eventParameters: [AHAPParameter]

    enum CodingKeys: String, CodingKey {
        case time             = "Time"
        case eventType        = "EventType"
        case eventDuration    = "EventDuration"
        case eventParameters  = "EventParameters"
    }
}

struct AHAPParameter: Codable {
    let parameterID: String
    let parameterValue: Double

    enum CodingKeys: String, CodingKey {
        case parameterID    = "ParameterID"
        case parameterValue = "ParameterValue"
    }
}
