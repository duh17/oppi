import Charts
import SwiftUI

enum ResourceUsageLoadError: LocalizedError {
    case notConnected
    case resourceMismatch

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Not connected to the server."
        case .resourceMismatch:
            "The server returned usage for a different resource."
        }
    }
}

struct ObservedUsageSection: View {
    typealias Request = (ResourceUsageRange, String) async throws -> ResourceUsageResponse

    let requestKey: ResourceUsageRequestKey
    let timezone: String
    let title: String
    let identifier: String
    let startsExpanded: Bool
    let initialRange: ResourceUsageRange
    let request: Request

    @State private var selectedRange: ResourceUsageRange
    @State private var response: ResourceUsageResponse?
    @State private var responseKey: ResourceUsageRequestKey?
    @State private var isLoading = true
    @State private var error: String?
    @State private var errorRequestID: String?
    @State private var isExpanded: Bool
    @State private var retryGeneration = 0

    init(
        requestKey: ResourceUsageRequestKey,
        timezone: String = TimeZone.current.identifier,
        title: String = "Observed Usage",
        identifier: String = "resourceUsage.details",
        startsExpanded: Bool = false,
        initialRange: ResourceUsageRange = .thirtyDays,
        request: @escaping Request
    ) {
        self.requestKey = requestKey
        self.timezone = timezone
        self.title = title
        self.identifier = identifier
        self.startsExpanded = startsExpanded
        self.initialRange = initialRange
        self.request = request
        _selectedRange = State(initialValue: initialRange)
        _isExpanded = State(initialValue: startsExpanded)
    }

    private var loadingIdentifier: String { "\(identifier).loading" }
    private var emptyIdentifier: String { "\(identifier).empty" }
    private var failureIdentifier: String { "\(identifier).failure" }

    private var requestID: String {
        [
            requestKey.serverId,
            requestKey.subject.kind.rawValue,
            requestKey.subject.id ?? "",
            String(selectedRange.rawValue),
            timezone,
            String(retryGeneration),
        ].joined(separator: "|")
    }

    private var currentResponse: ResourceUsageResponse? {
        ResourceUsagePresentation.response(
            response,
            responseKey: responseKey,
            requestKey: requestKey,
            range: selectedRange,
            timezone: timezone
        )
    }

    private var currentError: String? {
        ResourceUsagePresentation.error(
            error,
            errorRequestID: errorRequestID,
            requestID: requestID
        )
    }

    var body: some View {
        Section {
            Group {
                switch ResourceUsagePresentationState.resolve(
                    isLoading: isLoading,
                    response: currentResponse,
                    error: currentError
                ) {
                case .loading:
                    localLoading
                case .failure(let message):
                    localFailure(message)
                case .empty:
                    if let currentResponse {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(ResourceUsagePresentation.emptyMessage(for: selectedRange))
                                .font(.subheadline)
                                .foregroundStyle(.themeComment)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier(emptyIdentifier)
                            ResourceUsageSummaryView(usage: currentResponse)
                        }
                    }
                case .content:
                    if let currentResponse {
                        ResourceUsageSummaryView(usage: currentResponse)
                    }
                }
            }
            .themedListRowBackground()

            DisclosureGroup("Usage Details", isExpanded: $isExpanded) {
                rangePicker

                if let currentResponse {
                    ResourceUsageDetailContent(usage: currentResponse)
                } else if isLoading {
                    localLoading
                } else if let currentError {
                    localFailure(currentError)
                }
            }
            .accessibilityIdentifier(identifier)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .themedListRowBackground()
        } header: {
            Text(title)
                .foregroundStyle(.themeFg)
        }
        .themedListRowBackground()
        .foregroundStyle(.themeFg)
        .tint(.themeBlue)
        .task(id: requestID) { await load() }
        .onChange(of: requestKey) { _, _ in resetForNewRequest() }
        .onChange(of: timezone) { _, _ in resetForNewRequest() }
    }

    private func resetForNewRequest() {
        response = nil
        responseKey = nil
        error = nil
        errorRequestID = nil
        isLoading = true
    }

    private var rangePicker: some View {
        Picker("Range", selection: $selectedRange) {
            ForEach(ResourceUsageRange.allCases) { range in
                Text(range.shortLabel).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Observed usage range")
    }

    private var localLoading: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Loading observed usage…")
                .font(.subheadline)
                .foregroundStyle(.themeComment)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(loadingIdentifier)
    }

    private func localFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Unable to load observed usage", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.themeFg)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") { retryGeneration &+= 1 }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityIdentifier(failureIdentifier)
    }

    private func load() async {
        let requestedKey = requestKey
        let requestedRange = selectedRange
        let requestedRequestID = requestID
        isLoading = true
        error = nil
        errorRequestID = nil
        do {
            let result = try await request(requestedRange, timezone)
            guard !Task.isCancelled,
                  requestKey == requestedKey,
                  selectedRange == requestedRange,
                  requestID == requestedRequestID else { return }
            guard result.matches(
                requestKey: requestedKey,
                range: requestedRange,
                timezone: timezone
            ) else {
                throw ResourceUsageLoadError.resourceMismatch
            }
            response = result
            responseKey = requestedKey
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  requestKey == requestedKey,
                  selectedRange == requestedRange,
                  requestID == requestedRequestID else { return }
            self.error = error.localizedDescription
            errorRequestID = requestedRequestID
        }
        guard requestKey == requestedKey, requestID == requestedRequestID else { return }
        isLoading = false
    }
}

struct ToolActivitySection: View {
    typealias Request = (ResourceUsageRange, String) async throws -> ResourceUsageResponse
    typealias BackfillRequest = () async throws -> ResourceUsageBackfillStatus

    let requestKey: ResourceUsageRequestKey
    let timezone: String
    let startsExpanded: Bool
    let initialRange: ResourceUsageRange
    let request: Request
    let backfillStatusRequest: BackfillRequest
    let startBackfillRequest: BackfillRequest

    @State private var selectedRange: ResourceUsageRange
    @State private var response: ResourceUsageResponse?
    @State private var responseKey: ResourceUsageRequestKey?
    @State private var isLoading = false
    @State private var error: String?
    @State private var errorRequestID: String?
    @State private var isExpanded: Bool
    @State private var retryGeneration = 0
    @State private var backfillStatus: ResourceUsageBackfillStatus?
    @State private var backfillError: String?
    @State private var isStartingBackfill = false

    init(
        requestKey: ResourceUsageRequestKey,
        timezone: String = TimeZone.current.identifier,
        startsExpanded: Bool = false,
        initialRange: ResourceUsageRange = .thirtyDays,
        request: @escaping Request,
        backfillStatusRequest: @escaping BackfillRequest,
        startBackfillRequest: @escaping BackfillRequest
    ) {
        self.requestKey = requestKey
        self.timezone = timezone
        self.startsExpanded = startsExpanded
        self.initialRange = initialRange
        self.request = request
        self.backfillStatusRequest = backfillStatusRequest
        self.startBackfillRequest = startBackfillRequest
        _selectedRange = State(initialValue: initialRange)
        _isExpanded = State(initialValue: startsExpanded)
    }

    private var requestID: String {
        [
            requestKey.serverId,
            requestKey.subject.kind.rawValue,
            requestKey.subject.id ?? "",
            String(isExpanded),
            String(selectedRange.rawValue),
            timezone,
            String(retryGeneration),
        ].joined(separator: "|")
    }

    private var currentResponse: ResourceUsageResponse? {
        ResourceUsagePresentation.response(
            response,
            responseKey: responseKey,
            requestKey: requestKey,
            range: selectedRange,
            timezone: timezone
        )
    }

    private var currentError: String? {
        ResourceUsagePresentation.error(
            error,
            errorRequestID: errorRequestID,
            requestID: requestID
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $selectedRange) {
                    ForEach(ResourceUsageRange.allCases) { range in
                        Text(range.shortLabel).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Tool activity range")

                backfillControl

                if let currentResponse {
                    if currentResponse.recordedActions == 0 {
                        Text(ResourceUsagePresentation.emptyMessage(for: selectedRange))
                            .font(.subheadline)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("toolActivity.empty")
                    }
                    ResourceUsageSummaryView(usage: currentResponse)
                    ResourceUsageDetailContent(usage: currentResponse)
                } else if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading tool activity…")
                            .foregroundStyle(.themeComment)
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("toolActivity.loading")
                } else if let currentError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Unable to load tool activity")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.themeFg)
                        Text(currentError)
                            .font(.footnote)
                            .foregroundStyle(.themeComment)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { retryGeneration &+= 1 }
                    }
                    .accessibilityIdentifier("toolActivity.failure")
                }
            }
            .padding(.top, 10)
        } label: {
            Label("Tool Activity", systemImage: "hammer")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
        }
        .padding(12)
        .background(.themeComment.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.themeFg)
        .tint(.themeBlue)
        .accessibilityIdentifier("toolActivity.details")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .task(id: requestID) {
            guard isExpanded else { return }
            async let usageLoad: Void = load()
            async let backfillLoad: Void = loadBackfillStatus()
            _ = await (usageLoad, backfillLoad)
        }
        .onChange(of: requestKey) { _, _ in resetForNewRequest() }
        .onChange(of: timezone) { _, _ in resetForNewRequest() }
    }

    @ViewBuilder
    private var backfillControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch ResourceUsageBackfillControlPresentation.resolve(
                status: backfillStatus,
                error: backfillError,
                isLoading: backfillStatus == nil && backfillError == nil
            ) {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading usage history status…")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                }
            case .failure(let message):
                Label("Unable to load usage history status", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.medium))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.themeComment)
                Button("Retry status") {
                    Task { await loadBackfillStatus() }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("toolActivity.backfill.retryStatus")
            case .status(let status):
                if status.status == .running {
                    ProgressView(
                        value: Double(status.processedSources),
                        total: Double(max(status.totalSources, 1))
                    )
                    Text("Scanned \(status.processedSources) of \(status.totalSources) sources · \(status.historicalEvents) historical events retained")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.themeComment)
                } else if status.status == .partial {
                    Text(status.lastError ?? "Some sources were not fully indexed.")
                        .font(.footnote)
                        .foregroundStyle(.themeOrange)
                } else if status.status == .complete {
                    Label("Usage history backfill complete", systemImage: "checkmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.themeGreen)
                }

                if status.canStart {
                    Button(status.actionTitle) {
                        Task { await startBackfill() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isStartingBackfill)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("toolActivity.backfill.start")
                }
                if status.status == .available {
                    Text("Scans the complete server history snapshot available when started, including imported, discovered, and Mirror traces. Live capture continues for later activity.")
                        .font(.footnote)
                        .foregroundStyle(.themeComment)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("toolActivity.backfill.status")
    }

    private func resetForNewRequest() {
        response = nil
        responseKey = nil
        error = nil
        errorRequestID = nil
        isLoading = false
        backfillStatus = nil
        backfillError = nil
        isStartingBackfill = false
    }

    private func loadBackfillStatus(initial: ResourceUsageBackfillStatus? = nil) async {
        backfillError = nil
        do {
            var observedRunning = false
            let terminal = try await ResourceUsageBackfillPolling.poll(
                initial: initial,
                request: backfillStatusRequest,
                onUpdate: { status in
                    observedRunning = observedRunning || status.status == .running
                    backfillStatus = status
                }
            )
            if observedRunning, terminal.status != .running { retryGeneration &+= 1 }
        } catch is CancellationError {
            return
        } catch {
            backfillError = error.localizedDescription
        }
    }

    private func startBackfill() async {
        guard !isStartingBackfill else { return }
        isStartingBackfill = true
        defer { isStartingBackfill = false }
        do {
            let started = try await startBackfillRequest()
            backfillStatus = started
            backfillError = nil
            if started.status == .running {
                await loadBackfillStatus(initial: started)
            }
        } catch {
            backfillError = error.localizedDescription
        }
    }

    private func load() async {
        let requestedKey = requestKey
        let requestedRange = selectedRange
        let requestedRequestID = requestID
        isLoading = true
        error = nil
        errorRequestID = nil
        do {
            let result = try await request(requestedRange, timezone)
            guard !Task.isCancelled,
                  requestKey == requestedKey,
                  selectedRange == requestedRange,
                  isExpanded,
                  requestID == requestedRequestID else { return }
            guard result.matches(
                requestKey: requestedKey,
                range: requestedRange,
                timezone: timezone
            ) else {
                throw ResourceUsageLoadError.resourceMismatch
            }
            response = result
            responseKey = requestedKey
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  requestKey == requestedKey,
                  selectedRange == requestedRange,
                  isExpanded,
                  requestID == requestedRequestID else { return }
            self.error = error.localizedDescription
            errorRequestID = requestedRequestID
        }
        guard requestKey == requestedKey, requestID == requestedRequestID else { return }
        isLoading = false
    }
}

private struct ResourceUsageSummaryView: View {
    let usage: ResourceUsageResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    metric(summaryActionTitle, value: usage.recordedActions)
                    metric("Sessions", value: usage.distinctSessions)
                    metric("Active Days", value: usage.activeDays)
                }
                VStack(alignment: .leading, spacing: 8) {
                    compactMetric(summaryActionTitle, value: usage.recordedActions)
                    compactMetric("Sessions", value: usage.distinctSessions)
                    compactMetric("Active Days", value: usage.activeDays)
                }
            }

            if usage.subject.kind == .skill {
                LabeledContent("Explicit Activations") {
                    Text(explicitActivations, format: .number)
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.themeComment)
            }

            if usage.subject.kind == .skill, usage.loadedSessionSignal.actions > 0 {
                LabeledContent("Loaded into Session") {
                    Text("\(usage.loadedSessionSignal.actions) loads · \(usage.loadedSessionSignal.sessions) sessions")
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.themeComment)
            }

            LabeledContent("Last Recorded Use") {
                Text(lastRecordedUse)
                    .multilineTextAlignment(.trailing)
            }
            .font(.footnote)
            .foregroundStyle(.themeComment)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceUsagePresentation.summaryAccessibilityLabel(usage))
        .accessibilityValue("Last recorded use \(lastRecordedUse)")
    }

    private var summaryActionTitle: String {
        usage.subject.kind == .skill ? "Instruction Reads" : "Recorded Actions"
    }

    private var explicitActivations: Int {
        usage.breakdown
            .filter { $0.signal == .explicitActivation }
            .reduce(0) { $0 + $1.actions }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.themeFg)
            Text(title)
                .font(.caption)
                .foregroundStyle(.themeComment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func compactMetric(_ title: String, value: Int) -> some View {
        LabeledContent(title) {
            Text(value, format: .number)
                .monospacedDigit()
        }
        .font(.subheadline)
        .foregroundStyle(.themeFg)
    }

    private var lastRecordedUse: String {
        guard let timestamp = usage.lastRecordedAt else { return "None recorded" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: usage.timezone)
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp) / 1_000))
    }
}

private struct ResourceUsageDetailContent: View {
    let usage: ResourceUsageResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if usage.recordedActions == 0 {
                Text(ResourceUsagePresentation.emptyMessage(for: usage.range))
                    .font(.subheadline)
                    .foregroundStyle(.themeComment)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                dailyActivity
                breakdown
            }
            coverage
        }
        .padding(.vertical, 4)
    }

    private var dailyActivity: some View {
        let presentation = ResourceUsageDailyChartPresentation(usage: usage)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Daily Activity")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
                .accessibilityIdentifier("resourceUsage.dailyActivity")

            Chart(usage.daily) { row in
                BarMark(
                    x: .value("Date", row.date),
                    y: .value(presentation.valueLabel, row.actions)
                )
                .foregroundStyle(.themeComment)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier("resourceUsage.dailyChart")
            .chartLegend(.hidden)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(.themeComment.opacity(0.22))
                    AxisValueLabel {
                        if let count = value.as(Int.self) {
                            Text(count, format: .number)
                                .font(.caption2)
                                .foregroundStyle(.themeComment)
                        }
                    }
                }
            }
            .frame(height: 110)
        }
    }

    @ViewBuilder
    private var breakdown: some View {
        if usage.subject.kind == .tools {
            let groups = ResourceUsagePresentation.toolGroups(from: usage.breakdown)
            if !groups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.kind.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.themeFg)
                            ForEach(group.rows) { row in
                                breakdownRow(row)
                            }
                        }
                    }
                }
            }
        } else if !usage.breakdown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(usage.subject.kind == .skill ? "Signals" : "Contributions")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.themeFg)
                    .accessibilityIdentifier("resourceUsage.breakdownHeading")
                ForEach(usage.breakdown) { row in
                    breakdownRow(row)
                }
            }
        }
    }

    private func breakdownRow(_ row: ResourceUsageBreakdownRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                breakdownIdentity(row)
                Spacer(minLength: 8)
                breakdownCounts(row)
            }
            VStack(alignment: .leading, spacing: 4) {
                breakdownIdentity(row)
                breakdownCounts(row)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceUsagePresentation.breakdownAccessibilityLabel(row))
        .accessibilityIdentifier("resourceUsage.breakdown.\(row.id)")
    }

    private func breakdownIdentity(_ row: ResourceUsageBreakdownRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.name)
                .font(.subheadline)
                .foregroundStyle(.themeFg)
                .fixedSize(horizontal: false, vertical: true)
            Text(ResourceUsagePresentation.signalLabel(row.signal))
                .font(.caption)
                .foregroundStyle(.themeComment)
        }
    }

    private func breakdownCounts(_ row: ResourceUsageBreakdownRow) -> some View {
        Text("\(row.actions) actions · \(row.sessions) sessions")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.themeComment)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var coverage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Coverage")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.themeFg)
            Text(ResourceUsagePresentation.recordingStartedLabel(usage))
            Text(usage.capture.status == .active ? "Live capture: Current" : "Live capture: Partial")
            Text(ResourceUsagePresentation.historyCoverageLabel(usage))
            Text("Exact actions: \(usage.attribution.exactActions) · Inferred: \(usage.attribution.inferredActions)")
            Text("Retained history: Up to \(usage.retainedHistory.retentionDays) days")
        }
        .font(.caption)
        .foregroundStyle(.themeComment)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceUsagePresentation.coverageAccessibilityLabel(usage))
        .accessibilityIdentifier("resourceUsage.coverage")
    }

}
