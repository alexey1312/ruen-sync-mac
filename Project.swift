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
    ]),
    sources: ["RuEnSync/**"],
    resources: [
        "RuEnSync/Resources/**",
    ],
    entitlements: .file(path: "RuEnSync/RuEnSync.entitlements"),
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
    targets: [app, tests]
)
