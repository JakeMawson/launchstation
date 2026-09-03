import Foundation
import XCTest
@testable import LauncherCore

final class ExternalProcessModelsTests: XCTestCase {
    func testLSOFFieldParserGroupsDuplicateIPv4IPv6AndWildcardListenersByPID() throws {
        let fields = [
            "p101", "cnode\u{001B}[31m", "f12u", "n127.0.0.1:3000",
            "f13u", "n127.0.0.1:3000", // duplicate FD for the same endpoint
            "f14u", "n[::1]:3000", "f15u", "n*:8080",
            "\np202", "cpython3", "f3u", "n0.0.0.0:65535",
            "f4u", "nmalformed", // counted and ignored
        ]
        let data = Data((fields.joined(separator: "\0") + "\0").utf8)

        let parsed = LSOFFieldParser.parse(data)

        XCTAssertEqual(parsed.processes.map(\.pid), [101, 202])
        let node = try XCTUnwrap(parsed.processes.first { $0.pid == 101 })
        XCTAssertEqual(node.shortCommand, "node")
        XCTAssertEqual(
            node.endpoints,
            [
                ExternalListenerEndpoint(address: "127.0.0.1", port: 3000),
                ExternalListenerEndpoint(address: "::1", port: 3000),
                ExternalListenerEndpoint(address: "*", port: 8080),
            ]
        )
        XCTAssertEqual(parsed.processes.first { $0.pid == 202 }?.endpoints, [
            ExternalListenerEndpoint(address: "0.0.0.0", port: 65535),
        ])
        XCTAssertEqual(parsed.discardedFieldCount, 1)
    }

    func testLSOFFieldParserRejectsConnectionsInvalidPIDsAndInvalidPorts() {
        let fields = [
            "pnot-a-pid", "cbad", "n*:3000",
            "p303", "cserver", "n127.0.0.1:0", "n127.0.0.1:65536",
            "n127.0.0.1:4000->127.0.0.1:5000",
        ]
        let parsed = LSOFFieldParser.parse(Data((fields.joined(separator: "\0") + "\0").utf8))

        XCTAssertTrue(parsed.processes.isEmpty)
        XCTAssertGreaterThanOrEqual(parsed.discardedFieldCount, 4)
    }

    func testArgvRedactionRemovesSecretsWithoutDestroyingBenignPortArguments() throws {
        let secrets = [
            "env-secret-value",
            "database-password",
            "flag-secret-value",
            "query-secret-value",
            "sk-ant-abcdefghijklmno",
            "abcdefgh.ijklmnop.qrstuvwx",
        ]
        let summary = ExternalCommandRedactor.redact(
            argv: [
                "/usr/bin/env",
                "API_TOKEN=env-secret-value",
                "DATABASE_URL=postgres://user:database-password@localhost/db",
                "node", "server.js",
                "--api-key", "flag-secret-value",
                "--port", "3000",
                "https://localhost/path?token=query-secret-value&mode=dev",
                "sk-ant-abcdefghijklmno",
                "abcdefgh.ijklmnop.qrstuvwx",
            ],
            provenance: .processGroupLeader,
            sourcePID: 101
        )

        XCTAssertTrue(summary.redactionApplied)
        XCTAssertFalse(summary.isSafeDraftSource)
        XCTAssertTrue(summary.arguments.contains("--port"))
        XCTAssertTrue(summary.arguments.contains("3000"))
        XCTAssertTrue(summary.displayCommand.contains(ExternalCommandRedactor.redactionMarker))

        let encoded = String(decoding: try LauncherJSON.encoder().encode(summary), as: UTF8.self)
        for secret in secrets {
            XCTAssertFalse(encoded.contains(secret), "encoded summary leaked \(secret)")
        }
    }

    func testShellRedactionAndDisplaySanitizationRemoveSecretsAndTerminalControls() {
        let rawShell = "API_KEY='shell-secret' npm run dev -- --port 3000; "
            + "curl 'https://user:password@localhost/?token=query-secret'"
        let summary = ExternalCommandRedactor.redact(
            argv: ["/bin/zsh", "-lc", rawShell],
            provenance: .sameProcessGroupAncestor,
            sourcePID: 202
        )

        XCTAssertTrue(summary.redactionApplied)
        XCTAssertNotNil(summary.shellCommand)
        XCTAssertFalse(summary.displayCommand.contains("shell-secret"))
        XCTAssertFalse(summary.displayCommand.contains("password"))
        XCTAssertFalse(summary.displayCommand.contains("query-secret"))
        XCTAssertTrue(summary.displayCommand.contains(ExternalCommandRedactor.redactionMarker))

        let sanitized = ExternalCommandRedactor.sanitizeDisplayText(
            "safe\u{001B}[31mRED\u{001B}[0m\nnext\u{0007}"
        )
        XCTAssertTrue(sanitized.changed)
        XCTAssertEqual(sanitized.value, "safeRED next ")
        XCTAssertFalse(sanitized.value.contains("\u{001B}"))
        XCTAssertFalse(sanitized.value.contains("\n"))
    }

    func testCurlCredentialAndSensitiveHeaderArgumentsAreRedacted() throws {
        let summary = ExternalCommandRedactor.redact(
            argv: [
                "/usr/bin/curl",
                "-u", "person:password-value",
                "--proxy-user=proxy:proxy-password",
                "-H", "Content-Type: application/json",
                "--header", "Authorization: Basic encoded-secret",
                "--proxy-header", "X-API-Key: header-secret",
                "--header=Cookie: session=inline-cookie",
                "-sH", "X-API-Key: clustered-header-secret",
                "-sHX-API-Key: attached-clustered-header-secret",
                "DB_PASS=database-alias-secret",
                "MYSQL_PWD=mysql-alias-secret",
                "https://127.0.0.1:9000/health",
            ],
            provenance: .listenerProcess,
            sourcePID: 250
        )

        XCTAssertTrue(summary.redactionApplied)
        XCTAssertTrue(summary.arguments.contains("Content-Type: application/json"))
        let encoded = String(decoding: try LauncherJSON.encoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(encoded.contains("password-value"))
        XCTAssertFalse(encoded.contains("proxy-password"))
        XCTAssertFalse(encoded.contains("encoded-secret"))
        XCTAssertFalse(encoded.contains("header-secret"))
        XCTAssertFalse(encoded.contains("inline-cookie"))
        XCTAssertFalse(encoded.contains("clustered-header-secret"))
        XCTAssertFalse(encoded.contains("attached-clustered-header-secret"))
        XCTAssertFalse(encoded.contains("database-alias-secret"))
        XCTAssertFalse(encoded.contains("mysql-alias-secret"))
        XCTAssertGreaterThanOrEqual(
            summary.arguments.filter { $0.contains(ExternalCommandRedactor.redactionMarker) }.count,
            9
        )
    }

    func testUnbalancedSecretShellFallsBackToRedactionMarker() {
        let result = ExternalCommandRedactor.redactShellCommand("npm start --token 'unterminated-secret")
        XCTAssertTrue(result.redacted)
        XCTAssertFalse(result.value.contains("unterminated-secret"))
        XCTAssertTrue(result.value.contains(ExternalCommandRedactor.redactionMarker))
    }

    func testAttachedShortCredentialsAreRedactedFromArgvShellAndDrafts() throws {
        let argv = ExternalCommandRedactor.redact(
            argv: [
                "/usr/bin/curl",
                "-uperson:argv-secret",
                "-sucluster:attached-secret",
                "-4uuser:numeric-secret",
                "-#uuser:punctuation-secret",
                "-sU", "proxy:separated-secret",
                "https://localhost",
            ],
            provenance: .listenerProcess,
            sourcePID: 302
        )
        XCTAssertTrue(argv.redactionApplied)
        XCTAssertEqual(argv.arguments.first, "-u\(ExternalCommandRedactor.redactionMarker)")
        XCTAssertEqual(argv.arguments[1], "-su\(ExternalCommandRedactor.redactionMarker)")
        XCTAssertEqual(argv.arguments[2], "-4u\(ExternalCommandRedactor.redactionMarker)")
        XCTAssertEqual(argv.arguments[3], "-#u\(ExternalCommandRedactor.redactionMarker)")
        XCTAssertEqual(argv.arguments[4], "-sU")
        XCTAssertEqual(argv.arguments[5], ExternalCommandRedactor.redactionMarker)
        XCTAssertFalse(
            String(decoding: try LauncherJSON.encoder().encode(argv), as: UTF8.self)
                .contains("argv-secret")
        )
        XCTAssertFalse(argv.displayCommand.contains("attached-secret"))
        XCTAssertFalse(argv.displayCommand.contains("numeric-secret"))
        XCTAssertFalse(argv.displayCommand.contains("punctuation-secret"))
        XCTAssertFalse(argv.displayCommand.contains("separated-secret"))

        let shellCases = [
            ("curl -sUproxy:attached-secret https://localhost", "attached-secret"),
            ("curl -u person:separated-secret https://localhost", "separated-secret"),
            ("curl -U 'proxy:quoted-secret' https://localhost", "quoted-secret"),
            ("curl -4uuser:numeric-secret https://localhost", "numeric-secret"),
            ("curl -#uuser:punctuation-secret https://localhost", "punctuation-secret"),
            (#"curl -u user:escaped\ secret https://localhost"#, "escaped secret"),
            (#"curl -u user:'mixed secret' https://localhost"#, "mixed secret"),
            (#"curl '-u' user:quoted-option-secret https://localhost"#, "quoted-option-secret"),
            (#"curl -'4u' user:fragment-option-secret https://localhost"#, "fragment-option-secret"),
            (#"curl -\u user:escaped-option-secret https://localhost"#, "escaped-option-secret"),
            (#"curl --user=user:'long option secret' https://localhost"#, "long option secret"),
            (#"curl -H 'Cookie: session=header secret' https://localhost"#, "header secret"),
            (#"curl -sH X-API-Key:clustered-header-secret https://localhost"#, "clustered-header-secret"),
            (#"curl -sHX-API-Key:attached-header-secret https://localhost"#, "attached-header-secret"),
            (#"API_TOKEN=assignment:'mixed secret' tool start"#, "mixed secret"),
            (#"DB_PASS=database-alias-secret app"#, "database-alias-secret"),
            (#"MYSQL_PWD=mysql-alias-secret mysql"#, "mysql-alias-secret"),
            ("curl --us\\\ner user:line-continuation-secret https://localhost", "line-continuation-secret"),
            (#"curl $'-u' user:ansi-secret https://localhost"#, "ansi-secret"),
            (#"option=-u; curl "$option" user:dynamic-secret https://localhost"#, "dynamic-secret"),
            (#"curl {,-u} user:brace-secret https://localhost"#, "brace-secret"),
            (#"eval 'curl -uuser:eval-secret https://localhost'"#, "eval-secret"),
            (#"sh -c 'curl --user user:nested-shell-secret https://localhost'"#, "nested-shell-secret"),
            (#"printf 'curl -uuser:piped-secret https://localhost' | sh"#, "piped-secret"),
            (#"curl -? user:glob-secret https://localhost"#, "glob-secret"),
        ]
        for (command, secret) in shellCases {
            let shell = ExternalCommandRedactor.redactShellCommand(command)
            XCTAssertTrue(shell.redacted)
            XCTAssertEqual(shell.value, ExternalCommandRedactor.redactionMarker)
            XCTAssertFalse(shell.value.contains(secret))
        }

        let safeShell = ExternalCommandRedactor.redactShellCommand("npm run dev -- --port 4173")
        XCTAssertFalse(safeShell.redacted)
        XCTAssertFalse(safeShell.sanitized)
        XCTAssertEqual(safeShell.value, "npm run dev -- --port 4173")

        let draft = ExternalLauncherDraftProposal.make(from: makeObservation(command: argv))
        XCTAssertNil(draft.executable)
        XCTAssertTrue(draft.blockers.contains(.redactedCommand))
        XCTAssertFalse(
            String(decoding: try LauncherJSON.encoder().encode(draft), as: UTF8.self)
                .contains("argv-secret")
        )
    }

    func testRedactedDraftCannotSaveUntilUserReplacesCommandAndChoosesPortPolicy() {
        let command = ExternalCommandRedactor.redact(
            argv: ["/usr/bin/node", "server.js", "--token", "draft-secret"],
            provenance: .listenerProcess,
            sourcePID: 303
        )
        let observation = makeObservation(command: command)

        var draft = ExternalLauncherDraftProposal.make(from: observation)

        XCTAssertFalse(draft.canSave)
        XCTAssertNil(draft.executable, "a redacted source must not become runnable draft data")
        XCTAssertTrue(draft.blockers.contains(.redactedCommand))
        XCTAssertTrue(draft.blockers.contains(.commandReviewRequired))
        XCTAssertTrue(draft.blockers.contains(.portPolicyReviewRequired))

        draft.executable = "/usr/bin/node"
        draft.arguments = ["server.js", "--port", "${PORT}"]
        draft.displayCommand = "/usr/bin/node server.js --port '${PORT}'"
        draft.sourceHadRedactions = false
        draft.sourceWasSanitized = false
        draft.commandReviewComplete = true
        draft.portPolicy = ExternalDraftPortPolicy(mode: .automatic)

        XCTAssertTrue(draft.canSave)

        draft.arguments.append(ExternalCommandRedactor.redactionMarker)
        XCTAssertFalse(draft.canSave, "the literal redaction sentinel must always block saving")
    }

    func testSafeDraftPreservesStructuredCommandButStillRequiresPortReview() {
        let command = ExternalCommandRedactor.redact(
            argv: ["/usr/bin/python3", "-m", "http.server", "4100"],
            provenance: .processGroupLeader,
            sourcePID: 404
        )
        var draft = ExternalLauncherDraftProposal.make(from: makeObservation(command: command))

        XCTAssertEqual(draft.executable, "/usr/bin/python3")
        XCTAssertEqual(draft.arguments, ["-m", "http.server", "4100"])
        XCTAssertTrue(draft.commandReviewComplete)
        XCTAssertEqual(draft.blockers, [.portPolicyReviewRequired])

        draft.portPolicy = ExternalDraftPortPolicy(mode: .fixed, fixedPort: 4100)
        XCTAssertTrue(draft.canSave)
    }

    func testAutomaticDraftPortRequiresAnExplicitManagedPortConsumer() {
        let command = ExternalCommandRedactor.redact(
            argv: ["/usr/bin/python3", "-m", "http.server", "4100"],
            provenance: .processGroupLeader,
            sourcePID: 405
        )
        var draft = ExternalLauncherDraftProposal.make(from: makeObservation(command: command))
        draft.portPolicy = ExternalDraftPortPolicy(mode: .automatic)

        XCTAssertTrue(draft.blockers.contains(.managedPortConsumptionRequired))
        XCTAssertFalse(draft.canSave)

        XCTAssertEqual(draft.arguments, ["-m", "http.server", "4100"])
        draft.arguments[draft.arguments.index(before: draft.arguments.endIndex)] = "${PORT}"
        XCTAssertFalse(draft.blockers.contains(.managedPortConsumptionRequired))
        XCTAssertTrue(draft.canSave)
    }

    func testWildcardEndpointsExposeLoopbackPresentationWithoutChangingBinding() {
        let wildcardV4 = ExternalListenerEndpoint(address: "0.0.0.0", port: 5000)
        let wildcardV6 = ExternalListenerEndpoint(address: "[::]", port: 5001)

        XCTAssertTrue(wildcardV4.isWildcard)
        XCTAssertEqual(wildcardV4.loopbackHost, "127.0.0.1")
        XCTAssertTrue(wildcardV6.isWildcard)
        XCTAssertEqual(wildcardV6.address, "::")
        XCTAssertEqual(wildcardV6.displayValue, "[::]:5001")
    }

    private func makeObservation(command: ExternalCommandSummary) -> ExternalProcessObservation {
        ExternalProcessObservation(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000303")!,
            pid: 303,
            pidStartIdentity: "303:10:20",
            startedAt: Date(timeIntervalSince1970: 10),
            userID: 501,
            parentPID: 302,
            processGroupID: 303,
            processGroupLeaderPID: 303,
            processGroupLeaderStartIdentity: "303:10:20",
            executablePath: "/usr/bin/node",
            executableIdentity: ExternalExecutableIdentity(device: 1, inode: 2),
            workingDirectory: "/Users/example/project",
            command: command,
            endpoints: [ExternalListenerEndpoint(address: "127.0.0.1", port: 4100)],
            ownership: .external,
            observedAt: Date(timeIntervalSince1970: 20),
            canClose: true
        )
    }
}
