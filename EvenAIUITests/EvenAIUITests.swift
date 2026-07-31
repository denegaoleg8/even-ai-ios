import XCTest

@MainActor
final class EvenAIUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.exists)
    }

    /// Opens Settings and confirms the Account section renders one of its
    /// two terminal states (signed-out prompt, or a signed-in identity)
    /// once session restoration finishes — never stuck showing nothing.
    /// Deliberately doesn't assert *which* state, since that depends on
    /// whatever account this run's device identity already resolves to.
    func testSettingsShowsAccountSection() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Settings"].firstMatch.tap()

        let signInButton = app.buttons["settings.signInButton"]
        let signedInAccount = app.otherElements["settings.accountSignedIn"]
        let resolved = signInButton.waitForExistence(timeout: 10) || signedInAccount.waitForExistence(timeout: 10)
        XCTAssertTrue(resolved, "Account section must resolve to either a sign-in prompt or a signed-in identity")
    }

    /// Full navigation smoke test through the auth flow: Settings → sign-in
    /// prompt → Welcome → Create Account / Sign In, and back out via
    /// Cancel. Skips itself if the account already has credentials (a
    /// signed-in device has no "Sign In or Create Account" button to
    /// start from) rather than failing on an assumption about device state.
    func testAuthWelcomeNavigation() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Settings"].firstMatch.tap()

        let signInButton = app.buttons["settings.signInButton"]
        guard signInButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("Device already has a claimed account — nothing to sign into from here.")
        }
        signInButton.tap()

        let createAccountButton = app.buttons["welcome.createAccountButton"]
        let signInWelcomeButton = app.buttons["welcome.signInButton"]
        XCTAssertTrue(createAccountButton.waitForExistence(timeout: 5))
        XCTAssertTrue(signInWelcomeButton.exists)

        signInWelcomeButton.tap()
        let emailField = app.textFields["login.emailField"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["login.submitButton"].exists)

        // Sign In's submit button starts disabled until the form is valid.
        XCTAssertFalse(app.buttons["login.submitButton"].isEnabled)

        // Forgot Password opens its own explanatory sheet rather than
        // doing nothing or crashing. Its "Done" button needs its own
        // identifier, not a plain-label query: Settings' own "Done"
        // button (this sheet's presenter) stays in the accessibility
        // tree the whole time this sheet is on top of it, so
        // `app.buttons["Done"]` matches both and is ambiguous —
        // confirmed live, not theoretical, the first time this suite
        // ever actually ran.
        app.buttons["Forgot Password?"].tap()
        XCTAssertTrue(app.staticTexts["Password Reset Isn't Available Yet"].waitForExistence(timeout: 5))
        app.buttons["forgotPassword.doneButton"].tap()

        // Back to Welcome, then over to Sign Up, confirming its fields
        // render too. Scoped to the navigation bar by its actual title
        // (`app.navigationBars["Sign In"]`), not a global
        // `app.navigationBars.buttons.element(boundBy: 0)` — Settings'
        // own navigation bar (this sheet's presenter) stays in the
        // accessibility tree the whole time this sheet is on top of it,
        // so an unscoped index-0 query can silently grab a button from
        // the wrong navigation bar. Confirmed live: the first version of
        // this test, written before this suite could actually run,
        // picked the right element by luck in manual code review but not
        // in practice.
        app.navigationBars["Sign In"].buttons.element(boundBy: 0).tap()
        createAccountButton.tap()
        XCTAssertTrue(app.textFields["signup.emailField"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["signup.submitButton"].exists)
        XCTAssertFalse(app.buttons["signup.submitButton"].isEnabled)

        // Cancel closes the whole auth sheet, back to Settings — not just
        // one navigation level.
        app.navigationBars["Create Account"].buttons.element(boundBy: 0).tap()
        app.buttons["welcome.cancelButton"].tap()
        XCTAssertTrue(app.buttons["settings.signInButton"].waitForExistence(timeout: 5))
    }
}
