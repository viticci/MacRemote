import Foundation
import Testing
@testable import MacRemote

struct JSONValueTests {
    @Test func parsedFoundationZeroAndOneRemainNumbersBesideBooleans() throws {
        let parsed = try #require(
            JSONSerialization.jsonObject(
                with: Data("[0,1,false,true]".utf8),
                options: [.fragmentsAllowed]
            ) as? [Any]
        )

        #expect(JSONValue.fromJSONObject(parsed) == .array([
            .number(0),
            .number(1),
            .bool(false),
            .bool(true)
        ]))
    }

    @Test func nativeSwiftNumericAndBooleanValuesRemainDistinct() {
        #expect(JSONValue.fromJSONObject(0) == .number(0))
        #expect(JSONValue.fromJSONObject(1) == .number(1))
        #expect(JSONValue.fromJSONObject(1.5) == .number(1.5))
        #expect(JSONValue.fromJSONObject(false) == .bool(false))
        #expect(JSONValue.fromJSONObject(true) == .bool(true))
    }
}
