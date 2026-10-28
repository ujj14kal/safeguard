import XCTest

final class DefaultsTests: XCTestCase {
    func testReleaseSetOnlyDistressWordsOn() {
        XCTAssertEqual(
            Defaults.values(debug: false),
            DefaultSet(
                listenerOptIn: false, aiJudgeEnabled: false, cloudEarEnabled: false,
                cloudEarAlwaysOn: false, distressWordsEnabled: true,
                shoutingTriggersSOS: false, recordOnSOS: false, debugLogEnabled: false
            )
        )
    }

    func testDebugSetKeepsDeveloperDefaults() {
        let debug = Defaults.values(debug: true)
        XCTAssertFalse(debug.listenerOptIn, "listener stays opt-in everywhere")
        XCTAssertTrue(debug.aiJudgeEnabled)
        XCTAssertTrue(debug.cloudEarEnabled)
        XCTAssertTrue(debug.cloudEarAlwaysOn)
        XCTAssertTrue(debug.distressWordsEnabled)
        XCTAssertTrue(debug.shoutingTriggersSOS)
        XCTAssertTrue(debug.recordOnSOS)
        XCTAssertTrue(debug.debugLogEnabled)
    }

    func testCurrentMatchesBuildConfiguration() {
        #if DEBUG
            XCTAssertEqual(Defaults.current, Defaults.values(debug: true))
        #else
            XCTAssertEqual(Defaults.current, Defaults.values(debug: false))
        #endif
    }

    func testOwnedKeysCoverKnownState() {
        let keys = Set(Defaults.ownedKeys)
        for key in [
            "wearerName", "sosContactsJSON", "setupComplete", "setupStep",
            "listenerOptIn", "customSafePhrase", "customUnsafePhrase",
            "debugLogEnabled", "backendBaseURL",
        ] {
            XCTAssertTrue(keys.contains(key), "missing owned key: \(key)")
        }
        XCTAssertEqual(Defaults.ownedKeys.count, Set(Defaults.ownedKeys).count, "no duplicates")
    }
}

final class SetupMachineTests: XCTestCase {
    func testNavigationClampsAtBothEnds() {
        var machine = SetupMachine()
        XCTAssertTrue(machine.isFirst)
        machine.back()
        XCTAssertEqual(machine.step, .welcome)
        while !machine.isLast { machine.next() }
        XCTAssertEqual(machine.step, .done)
        machine.next()
        XCTAssertEqual(machine.step, .done)
    }

    func testStepOrderAndProgress() {
        XCTAssertEqual(
            SetupStep.allCases,
            [.welcome, .account, .name, .permissions, .contacts, .phrases, .listening, .dryRun, .done]
        )
        XCTAssertEqual(SetupMachine(step: .welcome).progress, 0, accuracy: 0.001)
        XCTAssertEqual(SetupMachine(step: .done).progress, 1, accuracy: 0.001)
    }

    func testAccountStepNeverBlocksSetup() {
        XCTAssertTrue(SetupMachine.canAdvance(from: .account))
    }

    func testNameValidation() {
        XCTAssertTrue(SetupMachine.nameValid("Meera"))
        XCTAssertTrue(SetupMachine.nameValid("  Meera  "), "trims")
        XCTAssertTrue(SetupMachine.nameValid(String(repeating: "a", count: 40)))
        XCTAssertFalse(SetupMachine.nameValid(""))
        XCTAssertFalse(SetupMachine.nameValid("   "))
        XCTAssertFalse(SetupMachine.nameValid(String(repeating: "a", count: 41)))
    }

    func testGating() {
        XCTAssertTrue(SetupMachine.canAdvance(from: .welcome))
        XCTAssertTrue(SetupMachine.canAdvance(from: .permissions), "denied never blocks")
        XCTAssertTrue(SetupMachine.canAdvance(from: .listening))
        XCTAssertTrue(SetupMachine.canAdvance(from: .done))
        XCTAssertFalse(SetupMachine.canAdvance(from: .name))
        XCTAssertTrue(SetupMachine.canAdvance(from: .name, name: "Meera"))
        XCTAssertFalse(SetupMachine.canAdvance(from: .contacts, agreedContacts: 1))
        XCTAssertTrue(SetupMachine.canAdvance(from: .contacts, agreedContacts: 2))
        XCTAssertFalse(SetupMachine.canAdvance(from: .phrases))
        XCTAssertTrue(SetupMachine.canAdvance(from: .phrases, phrasesValid: true))
        XCTAssertFalse(SetupMachine.canAdvance(from: .dryRun))
        XCTAssertTrue(SetupMachine.canAdvance(from: .dryRun, dryRunSeen: true))
    }

    func testFinishWarnsOnUnlinked() {
        XCTAssertEqual(SetupMachine.finishWarnings(unlinkedCount: 0), [])
        XCTAssertEqual(
            SetupMachine.finishWarnings(unlinkedCount: 2), [.contactsUnlinked]
        )
    }

    func testStepRawValueRoundTripsForResume() {
        for step in SetupStep.allCases {
            XCTAssertEqual(SetupStep(rawValue: step.rawValue), step)
        }
        XCTAssertNil(SetupStep(rawValue: 99))
    }
}

final class CodePhraseValidationTests: XCTestCase {
    func testValidPairPasses() {
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "open calculator", unsafe: "open app store"), []
        )
    }

    func testDefaultsPass() {
        let config = SafetyConfig()
        XCTAssertEqual(
            CodePhraseValidation.validate(
                safe: config.safePhrases[0], unsafe: config.unsafePhrases[0]
            ),
            []
        )
    }

    func testTooShort() {
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "hello", unsafe: "open app store"),
            [.tooShort]
        )
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "open calculator", unsafe: "go"),
            [.tooShort]
        )
    }

    func testSame() {
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "open calculator", unsafe: "open calculator"),
            [.same, .containsOther]
        )
    }

    func testContainsOther() {
        XCTAssertEqual(
            CodePhraseValidation.validate(
                safe: "open calculator now", unsafe: "open calculator"
            ),
            [.containsOther]
        )
        XCTAssertEqual(
            CodePhraseValidation.validate(
                safe: "open calculator", unsafe: "please open calculator app"
            ),
            [.containsOther]
        )
    }

    func testDistressWordRejected() {
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "help me", unsafe: "open app store"),
            [.isDistressWord]
        )
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "open calculator", unsafe: "bachao please"),
            []
        )
    }

    func testSafeContainingUnsafeDefaultCollides() {
        XCTAssertEqual(
            CodePhraseValidation.validate(
                safe: "please open app store now", unsafe: "open calculator"
            ),
            [.collidesWithDefault]
        )
    }

    func testUnsafeContainingSafeDefaultIsAllowed() {
        XCTAssertEqual(
            CodePhraseValidation.validate(
                safe: "open notes app", unsafe: "please open calculator now"
            ),
            []
        )
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(
            CodePhraseValidation.validate(safe: "Help Me", unsafe: "open app store"),
            [.isDistressWord]
        )
    }
}

final class IncidentHistoryTests: XCTestCase {
    private func entry(daysAgo: Double, cause: String = "distressWord") -> IncidentHistoryEntry {
        let start = Date().addingTimeInterval(-daysAgo * 86400)
        return IncidentHistoryEntry(
            startedAt: start, endedAt: start.addingTimeInterval(90), cause: cause,
            trackOutcomes: ["contacts": "done"], contactsAlerted: 2,
            contactNames: ["Meera"], evidenceSaved: 3, evidenceWaiting: 0,
            liveURL: "https://demo.test/live/x", evidenceSessionID: "sess1"
        )
    }

    func testNewestFirst() {
        var history = IncidentHistory()
        history.append(entry(daysAgo: 5))
        history.append(entry(daysAgo: 1))
        history.append(entry(daysAgo: 3))
        let gaps = history.entries.map { $0.startedAt }
        XCTAssertEqual(gaps, gaps.sorted(by: >))
    }

    func testRemoveOneAndAll() {
        var history = IncidentHistory(entries: [entry(daysAgo: 1), entry(daysAgo: 2)])
        history.remove(id: history.entries[0].id)
        XCTAssertEqual(history.entries.count, 1)
        history.removeAll()
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testPurgeDropsOlderThan30Days() {
        var history = IncidentHistory(entries: [
            entry(daysAgo: 29), entry(daysAgo: 31), entry(daysAgo: 60),
        ])
        history.purge()
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.entries[0].cause, "distressWord")
    }

    func testRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let history = IncidentHistory(entries: [entry(daysAgo: 1)])
        history.save(to: url)
        XCTAssertEqual(IncidentHistory.load(from: url), history)
    }

    func testNoTranscriptFields() throws {
        let data = try JSONEncoder().encode(entry(daysAgo: 1))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let keys = Set(json.keys)
        XCTAssertTrue(keys.isDisjoint(with: [
            "transcript", "transcripts", "appearance", "heard", "said",
            "people", "description",
        ]))
        XCTAssertTrue(keys.contains("cause"))
        XCTAssertTrue(keys.contains("contactNames"))
    }

    func testLoadToleratesGarbage() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json")
        try? "not json".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(IncidentHistory.load(from: url).entries.isEmpty)
        XCTAssertTrue(
            IncidentHistory.load(
                from: url.appendingPathExtension("missing")
            ).entries.isEmpty
        )
    }
}

final class DataWipeTests: XCTestCase {
    func testWipeLocalRemovesEverything() throws {
        let suite = "wipe-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in Defaults.ownedKeys {
            defaults.set("x", forKey: key)
        }
        let docs = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: docs) }
        try Data("[]".utf8).write(to: docs.appendingPathComponent(IncidentHistory.filename))
        let evidence = docs.appendingPathComponent("Evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: evidence.appendingPathComponent("seg.mp4"))

        let report = DataWipe.wipeLocal(defaults: defaults, documents: docs, domain: suite)

        XCTAssertEqual(Set(report.removedKeys), Set(Defaults.ownedKeys))
        let remaining = defaults.persistentDomain(forName: suite) ?? [:]
        for key in Defaults.ownedKeys {
            XCTAssertNil(remaining[key], key)
        }
        XCTAssertEqual(Set(report.removedFiles), [IncidentHistory.filename, "Evidence"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: docs.appendingPathComponent(IncidentHistory.filename).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: evidence.path))

        let again = DataWipe.wipeLocal(defaults: defaults, documents: docs, domain: suite)
        XCTAssertTrue(again.removedKeys.isEmpty, "idempotent")
        XCTAssertTrue(again.removedFiles.isEmpty, "idempotent")
    }

    func testClearQueueDropsPendingEvents() {
        MockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: [:]
            )!
            return (response, Data())
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let log = AppLog(
            session: URLSession(configuration: config),
            config: { VerifierConfig(baseURL: URL(string: "http://example.test:9")!) }
        )
        log.event("wipe", ["a": "b"])
        XCTAssertEqual(log.queuedCount, 1)
        log.clearQueue()
        XCTAssertEqual(log.queuedCount, 0)
    }
}
