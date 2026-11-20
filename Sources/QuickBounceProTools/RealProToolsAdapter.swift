import Foundation
import QuickBounceDomain

public actor RealProToolsAdapter: ProToolsControlling {
    private var controlClient: (any PTSLCommandSending)?
    private var exportClient: (any PTSLCommandSending)?
    private var eventClient: (any PTSLCommandSending)?
    private let clientFactory: @Sendable (String) throws -> any PTSLCommandSending
    private var connection: ProToolsConnection?
    private var hostRelease: PTSLHostRelease?
    private var negotiatedVersion: PTSLProtocolVersion = .v2026_04
    private let diagnostics: DiagnosticLogger?

    public init(diagnostics: DiagnosticLogger? = nil) {
        self.diagnostics = diagnostics
        self.clientFactory = { try PTSLRawClient(label: $0) }
    }

    init(diagnostics: DiagnosticLogger? = nil,
         clientFactory: @escaping @Sendable (String) throws -> any PTSLCommandSending) {
        self.diagnostics = diagnostics
        self.clientFactory = clientFactory
    }

    public func connect() async throws -> ProToolsConnection {
        if let connection { return connection }

        let control = try clientFactory("control")
        let exporter = try clientFactory("export")
        let events = try clientFactory("events")

        let controlID = try await register(control, role: "Control")
        _ = try await register(exporter, role: "Export")
        _ = try await register(events, role: "Events")

        let versionResponse = try await successful(
            control,
            command: .getPTSLVersion,
            version: .v2026_04
        )
        let versionObject = try jsonObject(versionResponse.bodyJSON)
        let major = int(versionObject["version"]) ?? Int(versionResponse.version.major)
        let minor = int(versionObject["version_minor"]) ?? Int(versionResponse.version.minor)
        let revision = int(versionObject["version_revision"]) ?? Int(versionResponse.version.revision)
        guard let release = PTSLHostRelease.fromHostResponse(
            major: Int32(major), minor: Int32(minor), revision: Int32(revision)
        ) else {
            throw QuickBounceError.unsupportedVersion("PTSL Host version \(major).\(minor).\(revision)")
        }
        guard release >= .v2024_03 else {
            throw QuickBounceError.unsupportedVersion(
                "Pro Tools/PTSL \(release); QuickBounce requires 2024.03 or newer"
            )
        }

        controlClient = control
        exportClient = exporter
        eventClient = events
        hostRelease = release
        negotiatedVersion = release.requestVersion
        let result = ProToolsConnection(
            status: .connected,
            connectionID: controlID,
            ptslVersion: release.description,
            capabilities: .forHostRelease(release)
        )
        connection = result
        await diagnostics?.record(
            category: "connection",
            action: "connected",
            fields: [
                "ptsl_host_version": release.description,
                "ptsl_request_version": "\(negotiatedVersion.major).\(negotiatedVersion.minor).\(negotiatedVersion.revision)",
                "embedded_ptsl_sdk": PTSLRawClient.bridgeSDKVersion,
                "track_id_setters": String(result.capabilities.trackIDSetters),
                "track_state_setters": String(result.capabilities.trackStateSetters)
            ]
        )
        return result
    }

    public func disconnect() async {
        controlClient?.cancel(wait: true)
        exportClient?.cancel(wait: true)
        eventClient?.cancel(wait: true)
        controlClient = nil
        exportClient = nil
        eventClient = nil
        connection = nil
        hostRelease = nil
        negotiatedVersion = .v2026_04
        await diagnostics?.record(category: "connection", action: "disconnected")
    }

    public func currentSessionInfo() async throws -> SessionInfo {
        try await currentSessionContext().info
    }

    public func currentSessionContext() async throws -> SessionContext {
        let client = try requireControl()
        let identity = try await currentSessionIdentity()
        let name = try jsonObject(try await successful(client, command: .getSessionName).bodyJSON)
        let rate = try jsonObject(try await successful(client, command: .getSessionSampleRate).bodyJSON)
        let depth = try jsonObject(try await successful(client, command: .getSessionBitDepth).bodyJSON)
        let format = try jsonObject(try await successful(client, command: .getSessionAudioFormat).bodyJSON)
        let timeCodeRateResponse = try? await successful(client, command: .getSessionTimeCodeRate)
        let timeCodeRateObject = timeCodeRateResponse.flatMap { try? jsonObject($0.bodyJSON) }
        let length = try jsonObject(try await successful(client, command: .getSessionLength).bodyJSON)
        let tracks = try await trackStates()

        let sampleRate = normalizedNumber(rate["sample_rate"], fallback: 48_000)
        let bitDepth = normalizedNumber(depth["current_setting"], fallback: 24)
        let lengthValue = string(length["session_length"]) ?? "0"
        // GetSessionLength is an older API whose response does not carry an
        // explicit TimelineLocationType. Some Sessions return integer samples,
        // others return a counter-formatted string. Preserve exact samples when
        // available; otherwise expose an unknown length rather than guessing a
        // frame rate or sending an invalid conversion request.
        let lengthSamples = Int64(lengthValue) ?? 0
        let info = SessionInfo(
            identity: identity,
            name: string(name["session_name"]) ?? URL(fileURLWithPath: identity.path).deletingPathExtension().lastPathComponent,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            fileFormat: Self.sessionAudioFormatDisplayName(
                string(format["current_setting"])
            ),
            trackCount: tracks.count,
            lengthSamples: lengthSamples,
            timeCodeRate: Self.sessionTimeCodeRate(
                string(timeCodeRateObject?["current_setting"])
            )
        )
        let after = try await currentSessionIdentity()
        guard after.instanceID == identity.instanceID, after.path == identity.path else {
            throw QuickBounceError.sessionIdentityMismatch
        }
        return SessionContext(info: info, trackStates: tracks)
    }

    /// PTSL returns enum identifiers intended for API clients rather than the
    /// product-facing names used by Pro Tools. Keep the translation at the
    /// adapter boundary so SessionInfo and the UI never expose SDK symbols.
    static func sessionAudioFormatDisplayName(_ value: String?) -> String {
        switch value {
        case "SAFormat_WAVE", "SAF_WAVE", "WAVE", "WAV":
            return "WAV"
        case "SAFormat_AIFF", "SAF_AIFF", "AIFF":
            return "AIFF"
        case let value?:
            return value
        case nil:
            return "WAV"
        }
    }

    /// Normalizes both legacy (`STCR_`) and modern (`STCRate_`) PTSL enum
    /// names. Drop-frame changes timecode numbering only, so it maps to the
    /// same physical cadence as its non-drop counterpart.
    static func sessionTimeCodeRate(_ value: String?) -> SessionTimeCodeRate? {
        guard let value else { return nil }
        if value.contains("23976") { return .fps23_976 }
        if value.contains("2997") { return .fps29_97 }
        if value.contains("47952") { return .fps47_952 }
        if value.contains("5994") { return .fps59_94 }
        if value.contains("11988") { return .fps119_88 }
        if value.contains("Fps120") { return .fps120 }
        if value.contains("Fps100") { return .fps100 }
        if value.contains("Fps60") { return .fps60 }
        if value.contains("Fps50") { return .fps50 }
        if value.contains("Fps48") { return .fps48 }
        if value.contains("Fps30") { return .fps30 }
        if value.contains("Fps25") { return .fps25 }
        if value.contains("Fps24") { return .fps24 }
        return nil
    }

    /// Reads only the minimum identity fields required to establish a Session
    /// allowlist guard. Contract harnesses call this before enumerating tracks
    /// or issuing any Session-mutating request.
    public func currentSessionIdentity() async throws -> SessionIdentity {
        let client = try requireControl()
        let ids = try jsonObject(try await successful(client, command: .getSessionIDs).bodyJSON)
        let path = try jsonObject(try await successful(client, command: .getSessionPath).bodyJSON)
        let pathObject = path["session_path"] as? [String: Any]
        let sessionPath = string(pathObject?["path"]) ?? string(path["path"]) ?? ""
        guard !sessionPath.isEmpty else {
            throw QuickBounceError.connection("Pro Tools did not return the current Session path")
        }
        return SessionIdentity(
            path: sessionPath,
            originID: string(ids["origin_id"]) ?? "",
            instanceID: string(ids["instance_id"]) ?? "",
            parentID: string(ids["parent_id"]),
            proToolsVersion: hostRelease?.description ?? "Unknown",
            ptslVersion: connection?.ptslVersion ?? PTSLRawClient.bridgeSDKVersion
        )
    }

    public func trackStates() async throws -> [TrackState] {
        let client = try requireControl()
        let pageSize = 256
        var offset = 0
        var rows: [[String: Any]] = []
        repeat {
            let response = try await successful(
                client,
                command: .getTrackList,
                body: ["pagination_request": ["limit": pageSize, "offset": offset]]
            )
            let bodies = response.bodyJSONChunks.isEmpty ? [response.bodyJSON] : response.bodyJSONChunks
            let parsing = DiagnosticTimer()
            var page: [[String: Any]] = []
            var reportedTotal: Int?
            for body in bodies where !body.isEmpty {
                let object = try jsonObject(body)
                page.append(contentsOf: object["track_list"] as? [[String: Any]] ?? [])
                let pagination = object["pagination_response"] as? [String: Any] ?? [:]
                if let total = int(pagination["total"]) {
                    reportedTotal = max(reportedTotal ?? 0, total)
                }
            }
            await diagnostics?.record(
                category: "track_list",
                action: "parsed_page",
                fields: [
                    "requested_offset": String(offset),
                    "requested_limit": String(pageSize),
                    "response_body_chunk_count": String(response.bodyJSONChunks.count),
                    "parsed_page_track_count": String(page.count),
                    "reported_total": reportedTotal.map(String.init) ?? "missing",
                    "json_parse_ms": parsing.field
                ]
            )
            rows.append(contentsOf: page)
            let total = reportedTotal ?? rows.count
            offset += page.count
            if page.isEmpty || rows.count >= total { break }
        } while true

        let states: [TrackState] = rows.enumerated().compactMap { fallbackIndex, row in
            guard let id = string(row["id"]), let name = string(row["name"]) else { return nil }
            let attributes = row["track_attributes"] as? [String: Any] ?? [:]
            let reference = TrackReference(
                id: id,
                name: name,
                index: int(row["index"]) ?? fallbackIndex,
                kind: string(row["type"]) ?? "Unknown",
                parentFolderID: string(row["parent_folder_id"])
            )
            return TrackState(
                track: reference,
                isSolo: bool(attributes["is_soloed"]),
                isMuted: bool(attributes["is_muted"]),
                isInactive: Self.inactiveAttribute(attributes["is_inactive"],
                    modernEnums: hostRelease.map { $0 >= .v2025_06 } == true)
            )
        }
        await diagnostics?.recordTrackStates(
            action: "get_track_list_parsed",
            states: states,
            fields: [
                "raw_track_row_count": String(rows.count),
                "discarded_track_row_count": String(rows.count - states.count)
            ]
        )
        return states
    }

    public func currentTimelineSelection() async throws -> SampleRange {
        try PTSLTimelineState.selection(from: await timelineResponse())
    }

    public func currentTimelineState() async throws -> TimelineState {
        try PTSLTimelineState.decode(await timelineResponse())
    }

    private func timelineResponse() async throws -> [String: Any] {
        let response = try await successful(
            try requireControl(),
            command: .getTimelineSelection,
            body: ["location_type": "TLType_Samples"]
        )
        return try jsonObject(response.bodyJSON)
    }

    public func setTimelineSelection(_ range: SampleRange) async throws {
        try await setTimelineState(.forBounce(range))
    }

    public func setTimelineState(_ state: TimelineState) async throws {
        _ = try await successful(
            try requireControl(),
            command: .setTimelineSelection,
            body: try PTSLRequestBodyFactory.setTimelineState(state)
        )
    }

    public func exportMixSources() async throws -> [ProToolsMixSource] {
        guard hostRelease.map({ $0 >= .v2025_06 }) == true else { return [] }
        let client = try requireControl()
        var sources: [ProToolsMixSource] = []
        for type in MixSourceType.allCases {
            let response = try await successful(
                client,
                command: .getExportMixSourceList,
                body: ["type": PTSLRequestBodyFactory.mixSourceName(type)]
            )
            let object = try jsonObject(response.bodyJSON)
            let names = object["source_list"] as? [String] ?? []
            sources.append(contentsOf: names.map { ProToolsMixSource(type: type, name: $0) })
        }
        return sources
    }

    @discardableResult
    public func apply(trackStates: [TrackState]) async throws -> [TrackState] {
        let client = try requireControl()
        let operationID = UUID().uuidString
        await diagnostics?.recordTrackStates(
            action: "apply_requested",
            states: trackStates,
            correlationID: operationID
        )
        let requestedStates = trackStates.filter {
            PTSLRequestBodyFactory.supportsMuteAndSoloState($0.track)
        }
        let identity = try await currentSessionIdentity()
        let originalReadback = try await self.trackStates()
        let currentStates = originalReadback.filter {
            PTSLRequestBodyFactory.supportsMuteAndSoloState($0.track)
        }
        let controllableStates = try TrackStateResolver.resolve(
            expected: requestedStates,
            against: currentStates
        )
        await diagnostics?.recordTrackStates(
            action: "apply_resolved",
            states: controllableStates,
            correlationID: operationID,
            fields: [
                "requested_track_count": String(trackStates.count),
                "supported_track_count": String(requestedStates.count),
                "live_track_count": String(currentStates.count),
                "addressing": connection?.capabilities.trackIDSetters == true
                    ? "track_ids" : "track_names"
            ]
        )
        // Solo is always name-addressed, including on Hosts with Mute by ID.
        do {
            let duplicateNames = Dictionary(grouping: controllableStates, by: { $0.track.name })
                .filter { !$0.key.isEmpty && $0.value.count > 1 }
                .map(\.key)
                .sorted()
            if let duplicate = duplicateNames.first {
                throw QuickBounceError.ambiguousTrackName(duplicate)
            }
        }
        var readback = originalReadback
        // A single full fallback handles Folder/Group side effects. Never
        // reuse a state cached across exports: PT can be edited externally.
        for attempt in 0...1 {
            let beforeWrite = try await currentSessionIdentity()
            guard beforeWrite.instanceID == identity.instanceID, beforeWrite.path == identity.path else {
                throw QuickBounceError.sessionIdentityMismatch
            }
            let mutations = TrackStateMutations.make(
                target: controllableStates, current: readback, full: attempt > 0
            )
            await diagnostics?.record(category: "track_state", action: "apply_commands",
                correlationID: operationID, fields: [
                    "attempt": String(attempt + 1),
                    "mute_changes": String(mutations.mutes.count),
                    "solo_commands": String(mutations.soloOn.count + mutations.soloOff.count)
                ])
            try await sendMutations(mutations, using: client)
            readback = try await self.trackStates()
            let after = try await currentSessionIdentity()
            guard after.instanceID == identity.instanceID, after.path == identity.path else {
                throw QuickBounceError.sessionIdentityMismatch
            }
            // Do not silently accept a track add/remove/rename while applying.
            guard Set(originalReadback.map(\.track)) == Set(readback.map(\.track)) else {
                throw QuickBounceError.invalidPlan("Session tracks changed while applying the Mix. Capture it again.")
            }
            if TrackStateVerification.firstIssue(expected: controllableStates, actual: readback) == nil { break }
            await diagnostics?.recordTrackStates(action: "apply_failed_readback",
                states: readback, correlationID: operationID, fields: ["attempt": String(attempt + 1)])
        }

        await diagnostics?.recordTrackStates(
            action: "apply_readback", states: readback, correlationID: operationID
        )
        if let issue = TrackStateVerification.firstIssue(expected: controllableStates, actual: readback) {
            await diagnostics?.record(category: "track_state", action: "apply_verification_failed",
                correlationID: operationID, fields: ["issue": String(describing: issue)])
            switch issue {
            case let .missingTrack(name): throw QuickBounceError.trackMissing(name)
            case let .ambiguousTrack(name): throw QuickBounceError.ambiguousTrackName(name)
            case let .stateMismatch(name): throw QuickBounceError.stateVerificationFailed(name)
            }
        }
        await diagnostics?.record(category: "track_state", action: "apply_verified",
            correlationID: operationID, fields: ["verified_track_count": String(controllableStates.count)])
        return readback
    }

    private func sendMutations(_ mutations: TrackStateMutations, using client: any PTSLCommandSending) async throws {
        for enabled in [false, true] {
            let mutedIDs = mutations.mutes.filter { $0.isMuted == enabled }.map(\.track.id)
            let mutedNames = mutations.mutes.filter { $0.isMuted == enabled }.map(\.track.name)
            if !mutedIDs.isEmpty {
                _ = try await successful(
                    client,
                    command: .setTrackMuteState,
                    body: PTSLRequestBodyFactory.setTrackMuteState(
                        trackIDs: mutedIDs,
                        trackNames: mutedNames,
                        enabled: enabled,
                        useTrackIDs: connection?.capabilities.trackIDSetters == true
                    )
                )
            }
            let soloNames = (enabled ? mutations.soloOn : mutations.soloOff).map(\.track.name)
            if !soloNames.isEmpty {
                _ = try await successful(
                    client,
                    command: .setTrackSoloState,
                    body: PTSLRequestBodyFactory.setTrackSoloState(
                        trackNames: soloNames,
                        enabled: enabled
                    )
                )
            }
        }

    }

    public func exportMix(_ request: ProToolsExportRequest) async throws -> ProToolsExportResult {
        guard let client = exportClient else { throw QuickBounceError.connection("Export client is not connected") }
        let body = try PTSLRequestBodyFactory.exportMix(
            request,
            capabilities: connection?.capabilities ?? .ptsl2026_04
        )
        let response = try await successful(client, command: .exportMix, body: body)
        return ProToolsExportResult(taskID: response.taskID, candidateURLs: [])
    }

    public func cancelActiveExport() async {
        exportClient?.cancel(wait: false)
    }

    public func waitUntilReady() async throws {
        let client = try requireControl()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        var lastFailure: Error?
        while clock.now < deadline {
            do {
                let response = try await successful(client, command: .hostReadyCheck)
                let object = try jsonObject(response.bodyJSON)
                if bool(object["is_host_ready"]) { return }
            } catch {
                lastFailure = error
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let detail = lastFailure.map { ": \($0.localizedDescription)" } ?? ""
        throw QuickBounceError.connection(
            "Pro Tools did not return to an idle command state\(detail)"
        )
    }

    public func importAudio(_ request: ImportAudioRequest) async throws {
        let client = try requireControl()
        do {
            _ = try await successful(
                client,
                command: .importAudio,
                body: PTSLRequestBodyFactory.importAudio(request)
            )
        } catch {
            throw QuickBounceError.diskSpaceFailure(for: error) ?? QuickBounceError.importFailed(error.localizedDescription)
        }
    }

    public func saveSession() async throws {
        _ = try await successful(try requireControl(), command: .saveSession)
    }

    public func closeSession() async throws {
        _ = try await successful(
            try requireControl(),
            command: .closeSession,
            body: ["save_on_close": false]
        )
    }

    public func openSession(at url: URL) async throws {
        var body: [String: Any] = ["session_path": url.path]
        if connection?.capabilities.openSessionBehaviorOptions == true {
            body["behavior_options"] = [:]
        }
        _ = try await successful(
            try requireControl(),
            command: .openSession,
            body: body
        )
    }

    private func register(_ client: any PTSLCommandSending, role: String) async throws -> String {
        let response = try await successful(
            client,
            command: .registerConnection,
            body: ["company_name": "QuickBounce", "application_name": "QuickBounce \(role)"],
            version: .v1
        )
        return string(try jsonObject(response.bodyJSON)["session_id"]) ?? ""
    }

    private func requireControl() throws -> any PTSLCommandSending {
        guard let controlClient else { throw QuickBounceError.connection("Control client is not connected") }
        return controlClient
    }

    private func successful(
        _ client: any PTSLCommandSending,
        command: PTSLCommand,
        body: [String: Any] = [:],
        version: PTSLProtocolVersion? = nil
    ) async throws -> PTSLRawResponse {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let bodyJSON = String(decoding: data, as: UTF8.self)
        let requestVersion = version ?? negotiatedVersion
        let correlationID = UUID().uuidString
        await diagnostics?.recordPTSLRequest(
            command: String(describing: command),
            version: requestVersion,
            bodyJSON: bodyJSON,
            correlationID: correlationID
        )
        let response: PTSLRawResponse
        let roundTrip = DiagnosticTimer()
        do {
            response = try await client.send(
                command,
                bodyJSON: bodyJSON,
                sessionID: "",
                version: requestVersion,
                headerJSON: "{}"
            )
        } catch {
            await diagnostics?.recordPTSLTransportFailure(
                command: String(describing: command),
                error: error,
                correlationID: correlationID
            )
            throw error
        }
        let roundTripMilliseconds = roundTrip.milliseconds
        await diagnostics?.recordPTSLResponse(
            command: String(describing: command),
            response: response,
            correlationID: correlationID,
            roundTripMilliseconds: roundTripMilliseconds
        )
        guard response.completed else {
            let detail = response.errorJSON.isEmpty ? response.bodyJSON : response.errorJSON
            let failure = PTSLTransportError.command(status: response.status, message: detail)
            if failure.indicatesInsufficientDiskSpace {
                throw QuickBounceError.insufficientDiskSpace(failure.localizedDescription)
            }
            throw failure
        }
        return response
    }

    private func jsonObject(_ json: String) throws -> [String: Any] {
        guard !json.isEmpty else { return [:] }
        let data = Data(json.utf8)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func inactiveAttribute(_ value: Any?, modernEnums: Bool) -> Bool? {
        guard let value else { return nil }
        // PTSL shifted the enum's numeric values in 2025.06: None is 1 in
        // modern Hosts and 0 in legacy Hosts. Unknown must not skip a setter.
        let number = (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
        if let number {
            if modernEnums {
                switch number { case 1: return false; case 2...4: return true; default: return nil }
            }
            switch number { case 0: return false; case 1...3: return true; default: return nil }
        }
        guard let text = (value as? String)?.lowercased() else { return nil }
        switch text {
        case "none", "tastate_none": return false
        case "setexplicitly", "setimplicitly", "setexplicitlyandimplicitly",
             "tastate_setexplicitly", "tastate_setimplicitly", "tastate_setexplicitlyandimplicitly": return true
        default: return nil
        }
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value.filter(\.isNumber)) }
        return nil
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value.lowercased() == "true" }
        return false
    }

    private func normalizedNumber(_ value: Any?, fallback: Int) -> Int {
        int(value) ?? fallback
    }

}
