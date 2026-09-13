import XCTest
@testable import LauncherCore

final class SkillPromptWordingTests: XCTestCase {
    func testEmptyStatusDefaultsToInstall() {
        let status = LauncherSkillStatus(skillName: "launchstation", version: "test", hosts: [])
        XCTAssertEqual(status.agentSkillPromptAction, "Install")
        XCTAssertTrue(status.needsAgentSkillInstallationPrompt)
    }

    func testWordingAndExistingVisibilityAcrossAllProductStates() {
        for codexState in LauncherSkillInstallationState.allCases {
            for claudeState in LauncherSkillInstallationState.allCases {
                for codexAvailable in [false, true] {
                    for claudeAvailable in [false, true] {
                        let status = LauncherSkillStatus(skillName: "launchstation", version: "test", hosts: [
                            host(.codex, state: codexState, available: codexAvailable),
                            host(.claudeCode, state: claudeState, available: claudeAvailable)
                        ])
                        let context = "Codex \(codexState)/\(codexAvailable), Claude \(claudeState)/\(claudeAvailable)"
                        XCTAssertEqual(status.agentSkillPromptAction,
                                       codexState == .outdated || claudeState == .outdated ? "Update" : "Install",
                                       context)
                        XCTAssertEqual(status.needsAgentSkillInstallationPrompt,
                                       !((codexAvailable && codexState == .current) ||
                                         (claudeAvailable && claudeState == .current)), context)
                    }
                }
            }
        }
    }

    func testRefreshTransitionsFromInstallToUpdateToHiddenAndBack() {
        var status = LauncherSkillStatus(skillName: "launchstation", version: "test", hosts: [
            host(.codex, state: .notInstalled, available: true),
            host(.claudeCode, state: .notInstalled, available: true)
        ])
        XCTAssertEqual(status.agentSkillPromptAction, "Install")
        status.hosts[0].state = .outdated
        XCTAssertTrue(status.needsAgentSkillInstallationPrompt)
        XCTAssertEqual(status.agentSkillPromptAction, "Update")
        status.hosts[0].state = .current
        XCTAssertFalse(status.needsAgentSkillInstallationPrompt)
        status.hosts[0].state = .notInstalled
        XCTAssertTrue(status.needsAgentSkillInstallationPrompt)
        XCTAssertEqual(status.agentSkillPromptAction, "Install")
    }

    private func host(_ host: LauncherSkillHost, state: LauncherSkillInstallationState,
                      available: Bool) -> LauncherSkillHostStatus {
        LauncherSkillHostStatus(host: host, available: available, installationPath: "/fixture/\(host.rawValue)",
                                state: state, message: "Isolated wording fixture")
    }
}
