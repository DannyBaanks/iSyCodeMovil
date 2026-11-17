import XCTest
@testable import IysCodeMovilCore

final class WdaElementReaderTests: XCTestCase {
    private let reader = WdaElementReader()

    func testParsesNestedWDAElementsAndMatchesRustDescription() {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeApplication type="XCUIElementTypeApplication" x="0" y="0" width="430" height="932">
            <XCUIElementTypeWindow type="XCUIElementTypeWindow" x="0" y="0" width="430" height="932">
              <XCUIElementTypeButton type="XCUIElementTypeButton" label="Display &amp; Brightness" name="com.apple.settings.displayAndBrightness" x="20" y="650" width="390" height="53">
                <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="Display &amp; Brightness" x="20" y="650" width="390" height="53"/>
              </XCUIElementTypeButton>
            </XCUIElementTypeWindow>
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """

        let elements = reader.parse(xml: xml)

        XCTAssertEqual(elements.count, 1, "the repeated child text is represented by its button")
        XCTAssertEqual(elements[0].kind, "Button")
        XCTAssertEqual(elements[0].label, "Display & Brightness")
        XCTAssertEqual(elements[0].name, "com.apple.settings.displayAndBrightness")
        XCTAssertEqual(
            reader.format(elements, limit: 150),
            "Button \"Display & Brightness\" id=\"com.apple.settings.displayAndBrightness\" @(215,676) 390x53"
        )
    }

    func testParsesCapturedWDAHomeTreeAndDropsRustNoise() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <XCUIElementTypeApplication type="XCUIElementTypeApplication" name=" " label=" " x="0" y="0" width="430" height="932">
          <XCUIElementTypeWindow type="XCUIElementTypeWindow" x="0" y="0" width="430" height="932">
            <XCUIElementTypeOther type="XCUIElementTypeOther" name="Home screen icons" x="0" y="0" width="430" height="932">
              <XCUIElementTypeIcon type="XCUIElementTypeIcon" name="设置" label="设置" value="1个新项目" x="129" y="604" width="84" height="106">
                <XCUIElementTypeOther type="XCUIElementTypeOther" name="设置" label="设置" x="129" y="604" width="84" height="106"/>
              </XCUIElementTypeIcon>
              <XCUIElementTypeIcon type="XCUIElementTypeIcon" name="时钟" label="时钟" x="228" y="402" width="73" height="95"/>
              <XCUIElementTypeIcon type="XCUIElementTypeIcon" name="第二页的 App" label="第二页的 App" x="890" y="402" width="73" height="95"/>
              <XCUIElementTypeButton type="XCUIElementTypeButton" name="com.apple.settings.displayAndBrightness" label="显示与亮度" x="20" y="650" width="390" height="53"/>
              <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="被顶出屏幕一半" x="100" y="-20" width="100" height="40"/>
              <XCUIElementTypeOther type="XCUIElementTypeOther" x="10" y="10" width="50" height="50"/>
              <XCUIElementTypeOther type="XCUIElementTypeOther" label="零宽" x="10" y="10" width="0" height="50"/>
              <XCUIElementTypeOther type="XCUIElementTypeOther" label="垂直滚动条, 1页" value="0%" x="412" y="113" width="30" height="736"/>
            </XCUIElementTypeOther>
          </XCUIElementTypeWindow>
        </XCUIElementTypeApplication>
        """

        let elements = reader.parse(xml: xml)

        XCTAssertEqual(elements.map(\.label), ["设置", "时钟", "显示与亮度", "被顶出屏幕一半"])
        XCTAssertEqual(elements[0].centerX, 171)
        XCTAssertEqual(elements[0].centerY, 657)
        XCTAssertEqual(elements[3].centerX, 150)
        XCTAssertEqual(elements[3].centerY, 10)
        XCTAssertEqual(
            reader.format(elements, limit: 3),
            "Icon \"设置\" value=\"1个新项目\" @(171,657) 84x106\n"
                + "Icon \"时钟\" @(264,450) 73x95\n"
                + "Button \"显示与亮度\" id=\"com.apple.settings.displayAndBrightness\" @(215,676) 390x53\n"
                + "…1 more not listed, narrow it down with filter"
        )
    }

    func testKeepsUnlabeledNamedAndValuedElementsAndDecodesUnicodeEntities() {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeApplication x="0" y="0" width="390" height="844">
            <XCUIElementTypeButton type="XCUIElementTypeButton" name="continue_button" x="20" y="30" width="120" height="48"/>
            <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="Café &amp; ☕️ 🚀" value="Crème &lt;3&gt; &quot;ok&quot; &apos;yes&apos; &#x1F642; &#233;" x="20" y="100" width="260" height="30"/>
            <XCUIElementTypeOther type="XCUIElementTypeOther" value="42" x="20" y="150" width="50" height="25"/>
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """

        let elements = reader.parse(xml: xml)

        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0].text, "continue_button")
        XCTAssertEqual(elements[0].id, "continue_button")
        XCTAssertEqual(elements[1].label, "Café & ☕️ 🚀")
        XCTAssertEqual(elements[1].value, "Crème <3> \"ok\" 'yes' 🙂 é")
        XCTAssertEqual(elements[2].value, "42")
        XCTAssertEqual(
            reader.format(elements, limit: 3),
            "Button \"continue_button\" @(80,54) 120x48\n"
                + "StaticText \"Café & ☕️ 🚀\" value=\"Crème <3> \"ok\" 'yes' 🙂 é\" @(150,115) 260x30\n"
                + "Other \"42\" value=\"42\" @(45,162) 50x25"
        )
    }

    func testDropsFullScreenEmptyDegenerateAndOffscreenElementsAndClipsVisibleCenter() {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeApplication x="0" y="0" width="430" height="932">
            <XCUIElementTypeOther type="XCUIElementTypeOther" label="Full screen" x="0" y="0" width="430" height="932"/>
            <XCUIElementTypeButton type="XCUIElementTypeButton" label="Zero width" x="20" y="20" width="0" height="20"/>
            <XCUIElementTypeButton type="XCUIElementTypeButton" label="Offscreen" x="500" y="20" width="40" height="20"/>
            <XCUIElementTypeButton type="XCUIElementTypeButton" label="Clipped" x="-50" y="0" width="100" height="20"/>
            <XCUIElementTypeButton type="XCUIElementTypeButton" x="20" y="40" width="40" height="20"/>
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """

        let elements = reader.parse(xml: xml)

        XCTAssertEqual(elements.map(\.label), ["Clipped"])
        XCTAssertEqual(elements[0].centerX, 25)
        XCTAssertEqual(elements[0].centerY, 10)
    }

    func testOffsetsWidgetChildrenAndDeduplicatesMatchingNodes() {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeApplication x="0" y="0" width="430" height="932">
            <XCUIElementTypeOther type="XCUIElementTypeOther" x="29" y="84" width="150" height="100">
              <XCUIElementTypeOther type="XCUIElementTypeOther" x="0" y="0" width="150" height="100">
                <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" label="示例市" x="19" y="19" width="52" height="13"/>
              </XCUIElementTypeOther>
            </XCUIElementTypeOther>
            <XCUIElementTypeIcon type="XCUIElementTypeIcon" label="Clock" x="300" y="600" width="60" height="60"/>
            <XCUIElementTypeIcon type="XCUIElementTypeIcon" label="Clock" x="300" y="600" width="60" height="60"/>
          </XCUIElementTypeApplication>
        </AppiumAUT>
        """

        let elements = reader.parse(xml: xml)

        XCTAssertEqual(elements.count, 2)
        XCTAssertEqual(elements[0].label, "示例市")
        XCTAssertEqual(elements[0].centerX, 74)
        XCTAssertEqual(elements[0].centerY, 110)
        XCTAssertEqual(elements[1].label, "Clock")
    }

    func testFormatAppliesLimitAndReportsEmptyScreenText() {
        let elements = [
            element(label: "One", x: 10),
            element(label: "Two", x: 20),
            element(label: "Three", x: 30)
        ]

        XCTAssertEqual(
            reader.format(elements, limit: 1),
            "Button \"One\" @(10,20) 20x10\n…2 more not listed, narrow it down with filter"
        )
        XCTAssertEqual(
            reader.format(elements, limit: 0),
            "No elements with text found\n…3 more not listed, narrow it down with filter"
        )
        XCTAssertEqual(reader.format([], limit: 150), "No elements with text found")
    }

    func testLongTextAndIdentifiersUseRustClippingRules() {
        let element = LocalElement(
            kind: "Button",
            label: String(repeating: "長", count: 81),
            name: "com.example." + String(repeating: "x", count: 50),
            value: "",
            centerX: 1,
            centerY: 2,
            width: 3,
            height: 4
        )

        let description = reader.format([element], limit: 1)

        XCTAssertTrue(description.hasPrefix("Button \"\(String(repeating: "長", count: 60))…(81 characters)\" id=\""))
        XCTAssertTrue(description.contains("…\" @(1,2) 3x4"))
    }

    func testResolveTapPrefersExactMatchesThenUsesCaseInsensitiveContainsAndIndex() throws {
        let elements = [
            element(label: "Search in Settings", x: 10),
            element(label: "Search", x: 20),
            element(label: "Search", x: 30)
        ]

        XCTAssertEqual(try reader.resolveTap(text: "Search", index: 0, in: elements).x, 20)
        XCTAssertEqual(try reader.resolveTap(text: "search", index: 2, in: elements).x, 30)
        XCTAssertEqual(try reader.resolveTap(text: "settings", index: 0, in: elements).x, 10)
    }

    func testResolveTapUsesValueAndReturnsRustEnglishErrors() throws {
        let target = LocalElement(
            kind: "TextField", label: "", name: "email", value: "user@example.com",
            centerX: 15, centerY: 25, width: 100, height: 40
        )
        let elements = [target]

        XCTAssertEqual(try reader.resolveTap(text: "example.com", index: 0, in: elements).y, 25)
        XCTAssertThrowsError(try reader.resolveTap(text: "missing", index: 0, in: elements)) {
            XCTAssertEqual(
                $0.localizedDescription,
                "Not found: no element contains \"missing\"; look at the screen with iphone_list_elements or a screenshot first"
            )
        }
        XCTAssertThrowsError(try reader.resolveTap(text: "email", index: 1, in: elements)) {
            XCTAssertEqual(
                $0.localizedDescription,
                "Only matched 1 (index out of range):\nTextField \"email\" value=\"user@example.com\" @(15,25) 100x40"
            )
        }
    }

    func testMalformedXMLKeepsTheSuccessfullyParsedPrefix() {
        let xml = """
        <AppiumAUT>
          <XCUIElementTypeApplication x="0" y="0" width="390" height="844">
            <XCUIElementTypeButton type="XCUIElementTypeButton" label="Before error" x="20" y="30" width="100" height="40"/>
            <XCUIElementTypeButton type="XCUIElementTypeButton" label='broken' x='not-a-number'
        """

        XCTAssertEqual(reader.parse(xml: xml).map(\.label), ["Before error"])
    }

    private func element(label: String, x: Int) -> LocalElement {
        LocalElement(
            kind: "Button", label: label, name: "", value: "",
            centerX: x, centerY: 20, width: 20, height: 10
        )
    }
}
