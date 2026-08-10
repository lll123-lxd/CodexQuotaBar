import XCTest
@testable import CodexQuotaBar

private enum LoginItemTestError: Error { case denied }

private final class FakeLoginItemManager: LoginItemManaging {
    var status: LoginItemStatus
    var registerResult: Result<Void, Error> = .success(())
    var unregisterResult: Result<Void, Error> = .success(())

    init(status: LoginItemStatus) {
        self.status = status
    }

    func register() throws {
        try registerResult.get()
        status = .enabled
    }

    func unregister() throws {
        try unregisterResult.get()
        status = .notRegistered
    }
}

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testStatusMappingAndApproval() {
        let manager = FakeLoginItemManager(status: .requiresApproval)
        let controller = LoginItemController(manager: manager)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)

        manager.status = .enabled
        controller.refresh()

        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testRegistrationFailureRollsBackToManagerStatus() {
        let manager = FakeLoginItemManager(status: .notRegistered)
        manager.registerResult = .failure(LoginItemTestError.denied)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(manager.status, .notRegistered)
    }

    func testSuccessfulUnregisterReadsRealStatus() {
        let manager = FakeLoginItemManager(status: .enabled)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(false)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(manager.status, .notRegistered)
    }
}
