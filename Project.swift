import ProjectDescription

// =============================================================================
// RuEnSync — macOS menubar app that syncs the active input source to a QMK
// keyboard over Raw HID. Drop-in replacement for qmk-hid-host.
// =============================================================================

let bundleId = "com.alexey1312.ruensync"
/// macOS 14.0 (Sonoma) is the floor — @Observable from the Observation module
/// is the lowest-OS-bound API we use. Lowering further would require switching
/// to ObservableObject/@Published throughout. MenuBarExtra, ImageRenderer,
/// SMAppService.mainApp are all 13.0+, well within budget.
let deploymentTarget: DeploymentTargets = .macOS("14.0")

/// Sparkle appcast — public. Hosted as a static file on GitHub Pages of this
/// repo. CI updates appcast.xml on every release tag.
let sparkleFeedURL = "https://alexey1312.github.io/ruen-sync-mac/appcast.xml"

/// EdDSA public key for Sparkle update verification. Paired private key lives
/// in the GitHub Actions secret SPARKLE_PRIVATE_KEY and is used to sign each
/// DMG. Generated via `Sparkle/bin/generate_keys` once; rotated only if the
/// private key leaks (would require shipping a new release with a new pubkey,
/// older installs stop receiving updates until the user reinstalls).
let sparklePublicEDKey = "9mG/dHCyFpSwLUIcen0RyO1WJgczqxNrZ3/YUBCuZ+Q="

let app = Target.target(
    name: "RuEnSync",
    destinations: [.mac],
    product: .app,
    bundleId: bundleId,
    deploymentTargets: deploymentTarget,
    infoPlist: .extendingDefault(with: [
        "LSUIElement": true,
        "LSMinimumSystemVersion": "14.0",
        "CFBundleDisplayName": "RuEnSync",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "NSHumanReadableCopyright": "Copyright © 2026 Aleksei Kakoulin. MIT License.",
        // Sparkle auto-update keys. SUFeedURL + SUPublicEDKey are the only
        // hard requirements; the rest are user-overridable defaults that
        // Sparkle persists into NSUserDefaults after first launch.
        "SUFeedURL": .string(sparkleFeedURL),
        "SUPublicEDKey": .string(sparklePublicEDKey),
        "SUEnableAutomaticChecks": true,
        "SUScheduledCheckInterval": 86400,
    ]),
    sources: ["RuEnSync/**"],
    resources: [
        "RuEnSync/Resources/**",
    ],
    entitlements: .file(path: "RuEnSync/RuEnSync.entitlements"),
    dependencies: [
        .package(product: "Sparkle"),
    ],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "SWIFT_STRICT_CONCURRENCY": "complete",
            "MACOSX_DEPLOYMENT_TARGET": "14.0",
            "ENABLE_HARDENED_RUNTIME": "YES",
            "CODE_SIGN_STYLE": "Manual",
            "CODE_SIGN_IDENTITY": "-",
            "PRODUCT_NAME": "RuEnSync",
            "MARKETING_VERSION": "1.0.0",
            "CURRENT_PROJECT_VERSION": "1",
        ]
    )
)

let tests = Target.target(
    name: "RuEnSyncTests",
    destinations: [.mac],
    product: .unitTests,
    bundleId: "\(bundleId).tests",
    deploymentTargets: deploymentTarget,
    infoPlist: .default,
    sources: ["RuEnSyncTests/**"],
    dependencies: [.target(name: "RuEnSync")],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "GENERATE_INFOPLIST_FILE": "YES",
        ]
    )
)

let project = Project(
    name: "RuEnSync",
    organizationName: "alexey1312",
    packages: [
        .remote(
            url: "https://github.com/sparkle-project/Sparkle.git",
            requirement: .upToNextMajor(from: "2.6.0")
        ),
    ],
    targets: [app, tests]
)
