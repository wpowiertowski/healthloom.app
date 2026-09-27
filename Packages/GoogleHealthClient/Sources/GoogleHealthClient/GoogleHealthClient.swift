// GoogleHealthClient
//
// Placeholder for WP-01 (project skeleton). Real content lands in WP-04
// (actor GoogleAuthManager - OAuth 2.0 + PKCE) and WP-05 (typed v4 REST client,
// GoogleDataPoint, GoogleDataTypeSchema, pagination, resilience). See
// implementation-plan.md WP-04/WP-05 and architecture.md §2.
//
// Depends on CoreModel and Secrets (architecture.md §2 dependency order).

import CoreModel
import Secrets

/// Marker enum identifying this module. Exists so the package has a compilable,
/// testable placeholder ahead of WP-04/WP-05's real client, and proves the
/// CoreModel + Secrets dependency wiring compiles.
public enum GoogleHealthClientPlaceholder {
    public static let moduleName = "GoogleHealthClient"

    /// References CoreModel and Secrets so the dependency edges are exercised
    /// at compile time, not just declared in the manifest.
    public static let dependsOn = [
        CoreModelPlaceholder.moduleName,
        SecretsPlaceholder.moduleName,
    ]
}
