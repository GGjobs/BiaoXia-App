import XCTest

final class MainFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    private func makeApp(profileFixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if profileFixture {
            app.launchEnvironment["BIAOXIA_UI_TEST_PROFILE_JSON"] = Self.profileFixtureJSON
        } else {
            app.launchEnvironment["BIAOXIA_UI_TEST_EMPTY_PROFILE"] = "1"
        }
        return app
    }

    private static let profileFixtureJSON = #"{"fullName":"林知夏","gender":"女","birthDate":"2004-09-18","school":"云岭未来大学","college":"智能工程学院","major":"数据科学与智能系统","studentID":"2023AI0427","phone":"13800004271","email":"lin.zhixia@example.test","address":"云岭市新知区星河路88号7栋302室","schemaVersion":3,"items":[{"id":"9FD1E4DA-4A1E-4F94-8D1B-A08B56D3A7EC","category":"project","fieldID":"project.demo","label":"校园数据可视化平台","value":"负责需求梳理与移动端原型。","components":{"赛道":"创意组","title":"校园数据可视化平台","角色":"项目负责人","描述":"负责需求梳理与移动端原型。"},"confidence":1,"state":"confirmed","sensitivity":"normal","isPreferred":true,"modifiedByUser":true,"sources":[],"updatedAt":800000000}]}"#

    @MainActor
    func testDemoAccessRejectsInvalidConfigurationAndCanDismiss() {
        let app = makeApp(profileFixture: false)
        app.launch()
        let access = app.buttons["open-demo-access"]
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        access.tap()
        let save = app.buttons["save-demo-access"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        let address = app.textFields["demo-access-address"]
        address.tap()
        address.typeText("http://example.invalid")
        let token = app.secureTextFields["demo-access-token"]
        token.tap()
        token.typeText("invalid-demo-credential")
        save.tap()
        XCTAssertTrue(app.staticTexts["请填写有效的 HTTPS 服务地址和演示凭证。"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["manage-profile"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testFreshLaunchGuidesToMaterialLibrary() {
        let app = makeApp(profileFixture: false)
        app.launch()

        XCTAssertTrue(app.buttons["manage-profile"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["start-form-filling"].isEnabled)
        app.buttons["manage-profile"].tap()
        XCTAssertTrue(app.staticTexts["从材料建立我的信息"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["add-profile-materials"].exists)
    }

    @MainActor
    func testCompletesBlankFormFillingFlow() {
        let app = makeApp()
        // A hidden legacy required value must not block the general PDF shown on screen.
        app.launchEnvironment["BIAOXIA_UI_TEST_PROFILE_JSON"] = Self.profileFixtureJSON
            .replacingOccurrences(of: "\"赛道\":\"创意组\",", with: "")
        app.launch()
        importDebugForm(app)
        XCTAssertFalse(app.staticTexts["还需补充：报名赛道"].exists)
        let field = app.descendants(matching: .any)["general-field-widget:f01"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { field.tap() }
        let currentName = field.value as? String ?? ""
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentName.count) + "Test Applicant")
        app.swipeUp()
        let position = app.buttons["字段含义与填写位置"].firstMatch
        for _ in 0..<3 where !position.isHittable { app.swipeDown() }
        position.tap()
        let x = app.textFields["X"]
        XCTAssertTrue(x.waitForExistence(timeout: 5))
        x.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { x.tap() }
        let oldValue = x.value as? String ?? ""
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "0.35")
        app.buttons["保存位置"].tap()
        XCTAssertFalse(app.alerts["提示"].exists)
        let generateBeforeCompletion = app.buttons["generate-filled-pdf"]
        XCTAssertFalse(generateBeforeCompletion.isEnabled)
        // Every visible required field must be confirmed before the completion screen.
        for (id, value) in [("f02", "Test English"), ("f03", "2004-09-18"),
                            ("f04", "test@example.test"), ("f05", "Test School"), ("f08", "Test Summary")] {
            let target = app.descendants(matching: .any)["general-field-widget:\(id)"]
            reveal(target, in: app)
            target.tap()
            if !app.keyboards.firstMatch.waitForExistence(timeout: 2) { target.tap() }
            // Tapping the center can leave the insertion point inside an existing date.
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let currentValue = target.value as? String ?? ""
            app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count) + value)
        }
        for label in ["本科", "Python"] {
            let option = app.buttons[label]
            for _ in 0..<12 where !option.isHittable { app.swipeDown() }
            reveal(option, in: app)
            option.tap()
        }
        let mapping = app.buttons["save-version-mapping"]
        reveal(mapping, in: app)
        mapping.tap()
        XCTAssertFalse(app.alerts["提示"].exists)
        let generate = app.buttons["generate-filled-pdf"]
        reveal(generate, in: app)
        XCTAssertTrue(generate.isEnabled)
        generate.tap()
        XCTAssertTrue(app.staticTexts["已生成填写结果"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["share-filled-pdf"].waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "import-edit-region-map-export"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testReviewedFieldsCanContinueLocallyWithoutSending() {
        let app = makeApp()
        app.launch()
        importDebugForm(app)
        let review = app.buttons["review-field-explanation"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        for _ in 0..<3 where !review.isHittable { app.swipeDown() }
        reveal(review, in: app)
        review.tap()
        let send = app.buttons["send-reviewed-explanation"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        reveal(send, in: app)
        XCTAssertFalse(send.isEnabled)
        let skip = app.buttons["continue-without-remote-explanation"]
        reveal(skip, in: app)
        skip.tap()
        XCTAssertFalse(send.exists)
        XCTAssertTrue(app.buttons["review-field-explanation"].exists)
    }

    @MainActor
    func testReviewedFieldsReachLiveRelay() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["T11B_LIVE_RELAY"] == "1", "Explicit live Relay run required")
        let app = makeApp()
        for key in ["BIAOXIA_RELAY_BASE_URL", "BIAOXIA_RELAY_CLIENT_TOKEN"] {
            app.launchEnvironment[key] = try XCTUnwrap(environment[key])
        }
        app.launch()
        importDebugForm(app)
        let review = app.buttons["review-field-explanation"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        for _ in 0..<3 where !review.isHittable { app.swipeDown() }
        reveal(review, in: app)
        review.tap()
        let allow = app.buttons["allow-remaining-explanation-texts"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        reveal(allow, in: app)
        allow.tap()
        let send = app.buttons["send-reviewed-explanation"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let finished = NSPredicate(format: "exists == false")
        expectation(for: finished, evaluatedWith: send)
        waitForExpectations(timeout: 30)
        XCTAssertFalse(app.alerts["提示"].exists)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "live-field-review-completed"
        image.lifetime = .keepAlways
        add(image)
    }

    @MainActor
    func testCloudFailureKeepsManualContinuationAvailable() {
        let app = makeApp()
        app.launchEnvironment["BIAOXIA_RELAY_BASE_URL"] = "https://127.0.0.1:1/"
        app.launchEnvironment["BIAOXIA_RELAY_CLIENT_TOKEN"] = "fictional-test-token"
        app.launch()
        importDebugForm(app)
        let review = app.buttons["review-field-explanation"]
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        for _ in 0..<3 where !review.isHittable { app.swipeDown() }
        reveal(review, in: app)
        review.tap()
        let allow = app.buttons["allow-remaining-explanation-texts"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5))
        reveal(allow, in: app)
        allow.tap()
        let send = app.buttons["send-reviewed-explanation"]
        send.tap()
        let warning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "云端解释失败")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 30))
        let skip = app.buttons["continue-without-remote-explanation"]
        reveal(skip, in: app)
        skip.tap()
        XCTAssertFalse(send.exists)
        let generate = app.buttons["generate-filled-pdf"]
        reveal(generate, in: app)
        XCTAssertFalse(generate.isEnabled)
    }

    @MainActor
    func testSelectedSnippetsReachLiveRelayAndExportPDF() throws {
        try runLiveComposition(prefix: "T15-project-pdf", completion: "已生成填写结果")
    }

    @MainActor
    func testSelectedSnippetsReachLiveRelayAndExportWord() throws {
        try runLiveComposition(prefix: "T15-project-word", completion: "Word 内容已写入")
    }

    @MainActor
    func testT16WholeFormReachesLiveRelayAndExportsPDF() throws {
        try runLiveWholeForm(prefix: "T15-project-pdf", completion: "已生成填写结果")
    }

    @MainActor
    func testT16WholeFormReachesLiveRelayAndExportsWord() throws {
        try runLiveWholeForm(prefix: "T15-project-word", completion: "Word 内容已写入")
    }

    @MainActor
    func testT16SelectAllPreviewsPackedBatchWithoutSending() throws {
        try runSelectAllBatchPreview(live: false)
    }

    @MainActor
    func testT16SelectAllUsesLiveBatches() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["T16_LIVE_RELAY"] == "1", "Explicit fictional live test required")
        try runSelectAllBatchPreview(live: true)
    }

    @MainActor
    private func runSelectAllBatchPreview(live: Bool) throws {
        let app = makeApp()
        let itemIDs = (0..<24).map { _ in UUID().uuidString }
        let items = itemIDs.enumerated().map { index, id in
            let label = String(format: "虚构项目%02d", index)
            return aiProjectItem(id: id, label: label, value: "\(label)：负责需求梳理、界面原型与检索页面实现。")
        }
        app.launchEnvironment["BIAOXIA_UI_TEST_PROFILE_JSON"] = try aiProjectProfileFixture(items: items)
        if live {
            for key in ["BIAOXIA_RELAY_BASE_URL", "BIAOXIA_RELAY_CLIENT_TOKEN"] {
                app.launchEnvironment[key] = try XCTUnwrap(ProcessInfo.processInfo.environment[key])
            }
        }
        app.launch()
        importDebugForm(app, prefix: "T15-project-pdf")
        let entry = app.buttons["plan-form-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        reveal(entry, in: app); entry.tap()
        let send = app.buttons["plan-form-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "New profile items must start with no cloud permission")
        allowAIProfileItems(itemIDs, in: app)

        // Opening permissions refreshes the new draft with all allowed items. Deselect one
        // before exercising the per-request Select All action; that action grants no access.
        let firstSource = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "虚构项目00")).firstMatch
        XCTAssertTrue(firstSource.waitForExistence(timeout: 10))
        reveal(firstSource, in: app); firstSource.tap()
        let selectAll = app.buttons["plan-form-select-all-sources"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 10))
        XCTAssertTrue(selectAll.isEnabled)
        reveal(selectAll, in: app); selectAll.tap()
        XCTAssertTrue(send.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "本次将发送 1 批")).firstMatch.exists)
        if live {
            reveal(send, in: app); send.tap()
            XCTAssertTrue(app.staticTexts["已完成 1 / 1 批"].waitForExistence(timeout: 100))
        }
        app.buttons["保存并关闭"].tap()
    }

    @MainActor
    private func runLiveWholeForm(prefix: String, completion: String) throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["T16_LIVE_RELAY"] == "1", "Explicit fictional live test required")
        let app = makeApp()
        let itemID = "937843B4-434B-4A50-B027-2ECEDFB17F04"
        app.launchEnvironment["BIAOXIA_UI_TEST_PROFILE_JSON"] = try aiProjectProfileFixture(items: [
            aiProjectItem(id: itemID, label: "虚构图书检索项目", value: "虚构图书检索项目：负责界面原型和检索页面实现。")
        ])
        for key in ["BIAOXIA_RELAY_BASE_URL", "BIAOXIA_RELAY_CLIENT_TOKEN"] {
            app.launchEnvironment[key] = try XCTUnwrap(environment[key])
        }
        app.launch()
        importDebugForm(app, prefix: prefix)

        let entry = app.buttons["plan-form-entry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        reveal(entry, in: app); entry.tap()
        let send = app.buttons["plan-form-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "No profile item may be sent before explicit permission")
        allowAIProfileItems([itemID], in: app)
        XCTAssertTrue(send.isEnabled)
        reveal(send, in: app); send.tap()
        let adopt = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan-form-adopt-field-")).firstMatch
        XCTAssertTrue(adopt.waitForExistence(timeout: 100))
        app.buttons["保存并关闭"].tap()
        let inlineAdopt = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "review-plan-adopt-")).firstMatch
        XCTAssertTrue(inlineAdopt.waitForExistence(timeout: 10))
        reveal(inlineAdopt, in: app); inlineAdopt.tap()
        XCTAssertTrue(app.staticTexts["已采用"].waitForExistence(timeout: 10))

        let generate = app.buttons[prefix.hasSuffix("word") ? "generate-filled-word" : "generate-filled-pdf"]
        reveal(generate, in: app); generate.tap()
        XCTAssertTrue(app.staticTexts[completion].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[prefix.hasSuffix("word") ? "share-filled-word" : "share-filled-pdf"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = prefix + "-t16-whole-form-export"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func runLiveComposition(prefix: String, completion: String) throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["T15_LIVE_RELAY"] == "1", "Explicit fictional live test required")
        let app = makeApp()
        let itemID = "937843B4-434B-4A50-B027-2ECEDFB17F04"
        app.launchEnvironment["BIAOXIA_UI_TEST_PROFILE_JSON"] = try aiProjectProfileFixture(items: [
            aiProjectItem(id: itemID, label: "虚构图书检索项目", value: "虚构图书检索项目：负责界面原型和检索页面实现。")
        ])
        for key in ["BIAOXIA_RELAY_BASE_URL", "BIAOXIA_RELAY_CLIENT_TOKEN"] {
            app.launchEnvironment[key] = try XCTUnwrap(environment[key])
        }
        app.launch()
        importDebugForm(app, prefix: prefix)
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan-field-entry-")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        reveal(entry, in: app); entry.tap()
        let send = app.buttons["plan-form-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(send.isEnabled, "Single-field filling shares the default-deny permission policy")
        allowAIProfileItems([itemID], in: app)
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan-form-adopt-field-")).firstMatch.exists)
        reveal(send, in: app); send.tap()
        let adopt = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "plan-form-adopt-field-")).firstMatch
        XCTAssertTrue(adopt.waitForExistence(timeout: 100))
        for _ in 0..<4 where !adopt.isHittable { app.swipeDown() }
        reveal(adopt, in: app); adopt.tap()
        XCTAssertTrue(app.staticTexts["已采用"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["保存并关闭"].tap()
        let generate = app.buttons[prefix.hasSuffix("word") ? "generate-filled-word" : "generate-filled-pdf"]
        reveal(generate, in: app); generate.tap()
        XCTAssertTrue(app.staticTexts[completion].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons[prefix.hasSuffix("word") ? "share-filled-word" : "share-filled-pdf"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = prefix + "-live-export"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func aiProjectItem(id: String, label: String, value: String) -> [String: Any] {
        ["id": id, "category": "project", "fieldID": "project.\(id)", "label": label,
         "value": value, "components": ["subjectID": "E287CC07-E49E-476E-A70E-AB16F7AD66B1",
             "title": label, "description": value], "confidence": 1, "state": "autoExtracted",
         "sensitivity": "normal", "isPreferred": false, "modifiedByUser": false,
         "sources": [], "updatedAt": 800000000]
    }

    private func aiProjectProfileFixture(items: [[String: Any]]) throws -> String {
        var profile = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.profileFixtureJSON.utf8)) as? [String: Any])
        let subject = "E287CC07-E49E-476E-A70E-AB16F7AD66B1"
        profile["subjects"] = [["id": subject, "kind": "selfPerson", "displayName": "虚构本人"]]
        profile["items"] = items
        // Local matching may offer a suggestion, but must leave the project target available to AI.
        profile["records"] = items.map { item in
            ["id": item["id"]!, "subjectID": subject, "kind": "project",
             "businessKey": "fictional-ui-\(item["id"]!)", "displayValue": item["value"]!,
             "components": ["title": item["label"]!, "description": item["value"]!],
             "sources": [], "confirmedComponentKeys": [], "updatedAt": 800000000] as [String: Any]
        }
        return try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: profile), encoding: .utf8))
    }

    @MainActor
    private func allowAIProfileItems(_ itemIDs: [String], in app: XCUIApplication) {
        let manage = app.buttons["manage-ai-sharing"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10))
        reveal(manage, in: app); manage.tap()
        for id in itemIDs {
            let permission = app.switches["ai-sharing-\(id)"]
            // Rows are created lazily; scroll by the label column so no switch is toggled.
            for _ in 0..<30 {
                if permission.waitForExistence(timeout: 1) { break }
                app.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(permission.exists)
            reveal(permission, in: app)
            XCTAssertEqual(permission.value as? String, "0", "The fixture must not pregrant AI access")
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: permission)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
            // The labelled toggle spans the row; its centre is label text, so tap the trailing knob.
            permission.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == true", "1"), object: permission)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 10), .completed)
        }
        app.buttons["完成"].tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.navigationBars["AI 可用资料"])
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
    }

    @MainActor
    private func importDebugForm(_ app: XCUIApplication, prefix: String = "T11B-debug-form") {
        let start = app.buttons["start-form-filling"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        app.buttons["choose-blank-form"].tap()
        let form = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
        if !form.waitForExistence(timeout: 5) {
            let browse = app.tabBars.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "浏览", "Browse")).firstMatch
            if browse.exists { browse.tap() }
            let local = app.descendants(matching: .any).matching(
                NSPredicate(format: "label IN %@", ["我的 iPhone", "我的iPhone", "On My iPhone"])
            ).firstMatch
            if local.waitForExistence(timeout: 3) { local.tap() }
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "file-picker-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(form.waitForExistence(timeout: 10), "Run Scripts/prepare-t11b-ui.py for this simulator first.")
        if form.exists { form.tap() }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app
        for _ in 0..<30 {
            if element.isHittable { return }
            // Drag the content margin above the keyboard, not the keyboard itself.
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.48))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.18)))
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    func testStartsRealFileImportWithoutBundledDemoEntry() {
        let app = makeApp()
        app.launch()

        let startButton = app.buttons["填写空白表"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()

        XCTAssertTrue(app.buttons["从“文件”选择 PDF 或 DOCX"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["使用虚构演示材料"].exists)
        app.buttons["取消"].tap()

        let recentTasks = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recent-task-")
        )
        let createdTask = recentTasks.firstMatch
        XCTAssertTrue(createdTask.waitForExistence(timeout: 5))
        let createdTaskIdentifier = createdTask.identifier
        createdTask.swipeLeft()
        app.buttons["删除"].tap()
        let alert = app.alerts["删除任务？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["删除"].tap()
        XCTAssertFalse(app.buttons[createdTaskIdentifier].waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecentTaskDeletionCanBeCancelledAndConfirmed() {
        let app = makeApp()
        app.launch()

        let recentTasks = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recent-task-")
        )
        let startButton = app.buttons["填写空白表"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()

        let createdTask = recentTasks.firstMatch
        XCTAssertTrue(createdTask.waitForExistence(timeout: 5))
        let createdTaskIdentifier = createdTask.identifier
        createdTask.swipeLeft()
        XCTAssertTrue(app.buttons["删除"].waitForExistence(timeout: 5))
        app.buttons["删除"].tap()

        let alert = app.alerts["删除任务？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["取消"].tap()
        let persistedTask = app.buttons[createdTaskIdentifier]
        XCTAssertTrue(persistedTask.waitForExistence(timeout: 5))

        persistedTask.swipeLeft()
        app.buttons["删除"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["删除"].tap()

        XCTAssertFalse(persistedTask.waitForExistence(timeout: 5))
    }

    @MainActor
    func testRecentTasksCanBeClearedAtOnceAfterConfirmation() {
        let app = makeApp()
        app.launch()

        let startButton = app.buttons["填写空白表"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()

        let clearButton = app.buttons["clear-recent-tasks"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))
        clearButton.tap()

        let alert = app.alerts["清空最近任务？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["取消"].tap()
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))

        clearButton.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["全部清空"].tap()

        XCTAssertFalse(clearButton.waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "recent-task-")
            ).count,
            0
        )
    }

    @MainActor
    func testProfileInformationCanBeClearedWithoutDeletingRecentTasks() {
        let app = makeApp()
        app.launch()

        let startButton = app.buttons["start-form-filling"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10))
        startButton.tap()
        XCTAssertTrue(app.buttons["取消"].waitForExistence(timeout: 10))
        app.buttons["取消"].tap()

        let recentTask = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "recent-task-")
        ).firstMatch
        XCTAssertTrue(recentTask.waitForExistence(timeout: 5))
        let recentTaskIdentifier = recentTask.identifier

        app.buttons["manage-profile"].tap()
        let clearButton = app.buttons["clear-profile-information"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 10))
        for _ in 0..<4 where !clearButton.isHittable {
            app.swipeUp()
        }
        clearButton.tap()

        let alert = app.alerts["清空我的信息？"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["取消"].tap()
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))

        clearButton.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["全部清空"].tap()
        XCTAssertFalse(clearButton.waitForExistence(timeout: 5))

        app.buttons["返回"].tap()
        XCTAssertTrue(app.staticTexts["建立我的信息"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["start-form-filling"].isEnabled)
        XCTAssertTrue(app.buttons[recentTaskIdentifier].exists)
    }
}
