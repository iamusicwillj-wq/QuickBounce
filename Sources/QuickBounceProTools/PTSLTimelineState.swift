import Foundation
import CoreFoundation
import QuickBounceDomain

enum PTSLTimelineState {
    static func selection(from object: [String: Any]) throws -> SampleRange {
        let range = try SampleRange(start: sample("in_time", in: object),
                                    end: sample("out_time", in: object))
        guard range.start >= 0, range.end >= range.start else {
            throw QuickBounceError.invalidPlan("Pro Tools returned invalid Timeline positions")
        }
        return range
    }

    static func decode(_ object: [String: Any]) throws -> TimelineState {
        try TimelineState(
            selection: selection(from: object),
            playStartMarker: sample("play_start_marker_time", in: object),
            preRollStart: sample("pre_roll_start_time", in: object),
            postRollStop: sample("post_roll_stop_time", in: object),
            preRollEnabled: flag("pre_roll_enabled", in: object),
            postRollEnabled: flag("post_roll_enabled", in: object)
        )
    }

    private static func sample(_ key: String, in object: [String: Any]) throws -> Int64 {
        // The protocol declares strings. Do not round large positions through
        // Double or invent missing roll boundaries from the selection.
        guard let text = object[key] as? String, let value = Int64(text) else {
            throw QuickBounceError.invalidPlan("Pro Tools returned missing or invalid Timeline field: \(key)")
        }
        return value
    }

    private static func flag(_ key: String, in object: [String: Any]) throws -> Bool {
        // Protobuf JSON may omit scalar false. A present value must be a JSON
        // boolean, not a number/string that Foundation can coerce to Bool.
        guard let raw = object[key] else { return false }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw QuickBounceError.invalidPlan("Pro Tools returned invalid Timeline flag: \(key)")
        }
        return number.boolValue
    }
}
