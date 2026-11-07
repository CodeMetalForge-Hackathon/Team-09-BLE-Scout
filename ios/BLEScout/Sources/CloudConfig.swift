import Foundation

/// Supabase relay the phones send to (see groundstation/supabase/schema.sql).
/// The anon / publishable key is meant to ship inside apps: row-level security only lets it
/// INSERT into `batches`, never read. The secret key lives only on the ground station.
enum CloudConfig {
    static let supabaseURL = "https://nvxxuveanjynzldzntrq.supabase.co"
    static let anonKey = "sb_publishable_D0iLyws3swx-NQGb4QA5Ew_0ZKFZLzY"

    static var isConfigured: Bool { !supabaseURL.contains("YOUR-") && !anonKey.contains("YOUR-") }
}
