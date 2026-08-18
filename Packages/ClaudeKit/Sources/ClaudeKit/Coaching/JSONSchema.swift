//
//  JSONSchema.swift
//  ClaudeKit
//

import Foundation

/// Small builders for the JSON Schema dialect structured outputs accept.
///
/// The schema is built in code rather than pasted as a literal so the character
/// limits and habit ids come from the same constants the verifier uses — a
/// schema that drifts from the verifier means either rejected valid answers or
/// accepted invalid ones.
public enum JSONSchema {

    /// An object with `additionalProperties: false` and — unless told otherwise
    /// — every property required.
    ///
    /// Strict structured outputs demand both: a property that is merely
    /// optional gets omitted under pressure, and open objects let the model
    /// invent fields we then ignore.
    public static func object(
        _ properties: [String: JSONValue],
        required: [String]? = nil,
        description: String? = nil,
        nullable: Bool = false
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": nullable ? .array([.string("object"), .string("null")]) : .string("object"),
            "properties": .object(properties),
            "required": .array((required ?? properties.keys.sorted()).map { .string($0) }),
            "additionalProperties": .bool(false)
        ]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    public static func string(
        description: String? = nil,
        maxLength: Int? = nil,
        minLength: Int? = nil,
        enumValues: [String]? = nil,
        nullable: Bool = false
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": nullable ? .array([.string("string"), .string("null")]) : .string("string")
        ]
        if let description { schema["description"] = .string(description) }
        if let maxLength { schema["maxLength"] = .int(maxLength) }
        if let minLength { schema["minLength"] = .int(minLength) }
        if let enumValues {
            // `null` has to appear in the enum too when the field is nullable,
            // otherwise a nullable enum can never be satisfied.
            var values = enumValues.map { JSONValue.string($0) }
            if nullable { values.append(.null) }
            schema["enum"] = .array(values)
        }
        return .object(schema)
    }

    public static func integer(
        description: String? = nil,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer")]
        if let description { schema["description"] = .string(description) }
        if let minimum { schema["minimum"] = .int(minimum) }
        if let maximum { schema["maximum"] = .int(maximum) }
        return .object(schema)
    }

    public static func number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("number")]
        if let description { schema["description"] = .string(description) }
        if let minimum { schema["minimum"] = .double(minimum) }
        if let maximum { schema["maximum"] = .double(maximum) }
        return .object(schema)
    }

    public static func boolean(description: String? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("boolean")]
        if let description { schema["description"] = .string(description) }
        return .object(schema)
    }

    public static func array(
        of items: JSONValue,
        description: String? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("array"),
            "items": items
        ]
        if let description { schema["description"] = .string(description) }
        if let minItems { schema["minItems"] = .int(minItems) }
        if let maxItems { schema["maxItems"] = .int(maxItems) }
        return .object(schema)
    }

}
