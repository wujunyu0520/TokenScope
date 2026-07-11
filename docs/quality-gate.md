# Quality gate

GitHub Actions is the authoritative release-verification environment for TokenScope. The `quality-gate` workflow runs on pull requests targeting `main`, pushes to `main`, and manual dispatches. It has read-only repository permissions and does not upload releases or use Apple Developer signing.

The workflow runs `Scripts/verify_release.sh`, which performs these checks in order:

1. Runs the Swift test suite in parallel with `swift test --parallel`.
2. Runs the privacy-preserving usage reconciliation script tests with `python3 -m unittest discover -s Tests/ScriptTests -p 'test_*.py'`.
3. Validates Simplified Chinese localization with `python3 Scripts/check_zh_hans_localization.py`.
4. Builds the release configuration with `swift build -c release`.
5. Packages `TokenScope.app` with `Scripts/package_app.sh` into a temporary directory outside the repository.
6. Verifies the packaged app with `codesign --verify --deep --strict --verbose=2`.

The verification script removes its temporary package directory when it exits. If `APP_OUTPUT_DIR` is provided by the caller, the script packages there and preserves that directory.

## Optional local verification

Full Xcode is optional for local development because GitHub Actions is authoritative. Users who install full Xcode can select it, accept its license, and run the same gate locally:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
Scripts/verify_release.sh
```

Systems configured only with Command Line Tools may be unable to run XCTest locally; that does not replace or weaken the required GitHub Actions result.
