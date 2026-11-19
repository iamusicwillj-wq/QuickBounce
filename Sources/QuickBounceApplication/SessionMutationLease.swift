import Foundation
import QuickBounceDomain

public actor SessionMutationLease {
    private var holder: UUID?

    public init() {}

    public func acquire(for jobID: UUID) throws {
        guard holder == nil || holder == jobID else {
            throw QuickBounceError.invalidPlan("Another job currently owns the Session Mutation Lease")
        }
        holder = jobID
    }

    public func release(for jobID: UUID) {
        if holder == jobID { holder = nil }
    }

    public func isHeld(by jobID: UUID) -> Bool { holder == jobID }
}
