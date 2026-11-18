import Foundation
import Testing
@testable import MacRemote

@Suite("Bridge argument coercion")
struct MCPBridgeArgumentCoercionTests {
    private let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "reminder_id": .object(["type": .string("integer")]),
            "completed": .object(["type": .string("boolean")]),
            "ratio": .object(["type": .string("number")]),
            "title": .object(["type": .string("string")]),
            "tags": .object(["type": .string("array")])
        ])
    ])

    @Test("Strings become the scalar the schema declares when the conversion is exact")
    func stringsToScalars() throws {
        let coerced = MCPBridgeArgumentCoercion.coerce(
            ["reminder_id": "32277", "completed": "true", "ratio": "0.5", "title": 42],
            toSchema: schema
        )
        #expect(coerced["reminder_id"] as? Int64 == 32277)
        #expect(coerced["completed"] as? Bool == true)
        #expect(coerced["ratio"] as? Double == 0.5)
        #expect(coerced["title"] as? String == "42")
    }

    @Test("Inexact or unknown values pass through untouched")
    func passThrough() {
        let coerced = MCPBridgeArgumentCoercion.coerce(
            ["reminder_id": "abc", "completed": "yes", "tags": "a,b", "extra": "1"],
            toSchema: schema
        )
        #expect(coerced["reminder_id"] as? String == "abc")
        #expect(coerced["completed"] as? String == "yes")
        #expect(coerced["tags"] as? String == "a,b")
        #expect(coerced["extra"] as? String == "1")
        #expect(MCPBridgeArgumentCoercion.coerce(["a": "1"], toSchema: nil)["a"] as? String == "1")
    }

    /// RemCTL's `set_completion` takes `{"reminder_ids":[12,34]}`. The server
    /// parses array items to strings, so the items must go back to integers.
    @Test("Array items become the scalar the schema's items declare")
    func arrayItemsToScalars() throws {
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "reminder_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")])
                ])
            ])
        ])
        let parsed = try #require(ToolArgumentValue.fromJSONObject([12, 34]))
        let coerced = MCPBridgeArgumentCoercion.coerce(
            ["reminder_ids": parsed.jsonValue.anyValue],
            toSchema: schema
        )
        #expect(coerced["reminder_ids"] as? [Int64] == [12, 34])
    }

    @Test("Already typed values are never rewritten")
    func typedValuesStay() {
        let coerced = MCPBridgeArgumentCoercion.coerce(
            ["reminder_id": 7, "completed": false, "title": "x"],
            toSchema: schema
        )
        #expect(coerced["reminder_id"] as? Int == 7)
        #expect(coerced["completed"] as? Bool == false)
        #expect(coerced["title"] as? String == "x")
    }
}
