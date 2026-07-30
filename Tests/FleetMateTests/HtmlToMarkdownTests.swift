import XCTest
@testable import FleetMateCore

/// The converter feeding MarkdownUI everything Azure DevOps sends as HTML.
/// Each case is a shape ADO's editor actually produces.
final class HtmlToMarkdownTests: XCTestCase {

    func testParagraphsGetBlankLinesBetweenThem() {
        let md = HtmlToMarkdown.convert("<p>First paragraph.</p><p>Second paragraph.</p>")
        XCTAssertEqual(md, "First paragraph.\n\nSecond paragraph.")
    }

    func testDivsBreakLinesWithoutParagraphAir() {
        let md = HtmlToMarkdown.convert("<div>line one</div><div>line two</div>")
        XCTAssertEqual(md, "line one\nline two")
    }

    func testBoldItalicAndInlineCode() {
        let md = HtmlToMarkdown.convert("<b>bold</b> and <i>italic</i> and <code>deploy.ps1</code>")
        XCTAssertEqual(md, "**bold** and *italic* and `deploy.ps1`")
    }

    func testStrongWithTrailingSpaceDoesNotBreakTheMarker() {
        // "**not actually a deploy. **" renders as literal asterisks — the
        // closing marker has to move inside the whitespace.
        let md = HtmlToMarkdown.convert("<b>not actually a deploy. </b>It runs")
        XCTAssertEqual(md, "**not actually a deploy.** It runs")
    }

    func testUnorderedListKeepsBulletsAndNesting() {
        let md = HtmlToMarkdown.convert(
            "<ul><li>first</li><li>second<ul><li>nested</li></ul></li></ul>"
        )
        XCTAssertEqual(md, "- first\n- second\n    - nested")
    }

    func testOrderedListNumbersItems() {
        let md = HtmlToMarkdown.convert("<ol><li>one</li><li>two</li></ol>")
        XCTAssertEqual(md, "1. one\n2. two")
    }

    func testListItemsWithBoldAndCode() {
        let md = HtmlToMarkdown.convert(
            "<ul><li><code>deploy-api.{ps1,sh}</code> — delete. <b>Replaced.</b></li></ul>"
        )
        XCTAssertEqual(md, "- `deploy-api.{ps1,sh}` — delete. **Replaced.**")
    }

    func testTableBecomesAMarkdownTable() {
        // Reduced from work item 3943's "Target split", which flattened into
        // one line per cell in the old renderer.
        let html = """
        <table>
        <tr><th>Concern</th><th>Repo</th></tr>
        <tr><td>API image build</td><td>reportmate-api (public)</td></tr>
        <tr><td>Web image build</td><td>reportmate-app-web (public)</td></tr>
        </table>
        """
        let md = HtmlToMarkdown.convert(html)
        XCTAssertEqual(md, """
        | Concern | Repo |
        | --- | --- |
        | API image build | reportmate-api (public) |
        | Web image build | reportmate-app-web (public) |
        """)
    }

    func testTableWithoutHeaderRowStillRenders() {
        let md = HtmlToMarkdown.convert(
            "<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>"
        )
        XCTAssertEqual(md, "| a | b |\n| --- | --- |\n| c | d |")
    }

    func testPipesInsideCellsAreEscaped() {
        let md = HtmlToMarkdown.convert("<table><tr><td>a | b</td></tr></table>")
        XCTAssertEqual(md, "| a \\| b |\n| --- |")
    }

    func testPreBecomesAFencedBlock() {
        let md = HtmlToMarkdown.convert("<pre>az login\naz account set</pre>")
        XCTAssertEqual(md, "```\naz login\naz account set\n```")
    }

    func testEntitiesDecode() {
        let md = HtmlToMarkdown.convert("<div>teams_webhook_url = &quot;&quot; &amp; more&nbsp;here &#8212; done</div>")
        XCTAssertEqual(md, "teams_webhook_url = \"\" & more here — done")
    }

    func testLinksKeepTextAndHref() {
        let md = HtmlToMarkdown.convert(#"<a href="https://example.com/x">the docs</a>"#)
        XCTAssertEqual(md, "[the docs](https://example.com/x)")
    }

    func testHeadingsMapToHashes() {
        let md = HtmlToMarkdown.convert("<h2>Scope</h2><div>body</div>")
        XCTAssertEqual(md, "## Scope\n\nbody")
    }

    func testUnknownTagsAreDroppedTextKept() {
        let md = HtmlToMarkdown.convert(#"<span style="color:red">just text</span>"#)
        XCTAssertEqual(md, "just text")
    }

    func testBrInsideDivMakesALineBreak() {
        let md = HtmlToMarkdown.convert("<div>one<br>two</div>")
        XCTAssertEqual(md, "one\ntwo")
    }

    func testSourceNewlinesDoNotFakeParagraphs() {
        // ADO pretty-prints its HTML; literal newlines between words are
        // whitespace, not structure.
        let md = HtmlToMarkdown.convert("<div>one\ntwo</div>")
        XCTAssertEqual(md, "one two")
    }

    func testAdoRealisticFragment() {
        let html = """
        <div>The <code>reportmate-alerts</code> Azure Function App has <b>no CI at all</b>.</div>\
        <div><b>Scope</b></div>\
        <ul>\
        <li>New ADO pipeline deploying <code>functions/</code>.</li>\
        <li>Trigger on changes under <code>functions/</code>, plus manual dispatch.</li>\
        </ul>
        """
        let md = HtmlToMarkdown.convert(html)
        XCTAssertEqual(md, """
        The `reportmate-alerts` Azure Function App has **no CI at all**.
        **Scope**

        - New ADO pipeline deploying `functions/`.
        - Trigger on changes under `functions/`, plus manual dispatch.
        """)
    }
}
