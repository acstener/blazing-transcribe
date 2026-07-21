import XCTest
@testable import App

final class AppViewModelLicensePresentationTests: XCTestCase {
    func testUnresolvedNoKeyShowsLoadingInsteadOfBlockingGate() {
        let viewModel = AppViewModel()
        viewModel.licenseStatus = .noKey
        viewModel.hasResolvedInitialLicenseStatus = false

        XCTAssertTrue(viewModel.shouldShowLicenseResolutionLoading)
        XCTAssertFalse(viewModel.shouldShowBlockingLicenseGate)
    }

    func testResolvedFreeTierDoesNotShowBlockingGate() {
        let viewModel = AppViewModel()
        viewModel.licenseStatus = .freeTier
        viewModel.hasResolvedInitialLicenseStatus = true

        XCTAssertFalse(viewModel.shouldShowLicenseResolutionLoading)
        XCTAssertFalse(viewModel.shouldShowBlockingLicenseGate)
        XCTAssertTrue(viewModel.isAppAccessible)
    }

    func testResolvedValidationFailureShowsBlockingGate() {
        let viewModel = AppViewModel()
        viewModel.licenseStatus = .validationUnavailable("offline")
        viewModel.hasResolvedInitialLicenseStatus = true

        XCTAssertFalse(viewModel.shouldShowLicenseResolutionLoading)
        XCTAssertTrue(viewModel.shouldShowBlockingLicenseGate)
        XCTAssertFalse(viewModel.isAppAccessible)
    }
}
