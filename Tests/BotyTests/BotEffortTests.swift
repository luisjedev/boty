import XCTest

@testable import Boty

final class BotEffortTests: XCTestCase {
    /// El desplegable de esfuerzo ofrece exactamente los tiers que acepta
    /// `muse exec --reasoning-effort`, en su mismo orden.
    func testEffortsMatchMuseCLI() {
        XCTAssertEqual(
            Bot.efforts,
            ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        )
    }

    /// Cada tier del desplegable llega tal cual a `--reasoning-effort`.
    func testEveryEffortReachesExecArgs() {
        for effort in Bot.efforts {
            let args = museExecArgs(
                request: MuseRequest(
                    sessionId: "s1", prompt: "hola", model: "", effort: effort,
                    workspace: "/tmp/work", allowTools: false
                ),
                promptPath: "/tmp/prompt.txt"
            )
            let flag = args.firstIndex(of: "--reasoning-effort")
            XCTAssertNotNil(flag, "falta --reasoning-effort para \(effort)")
            XCTAssertEqual(args[flag! + 1], effort)
        }
    }
}
