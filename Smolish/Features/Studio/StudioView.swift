import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudioViewModel: ObservableObject {
    @Published private(set) var videos: [StudioVideo] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var analytics = StudioAnalytics(metrics: [], points: [])
    @Published var errorMessage: String?
    @Published var selectedDays = 30
    private var page = 1

    func load(reset: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if reset { page = 1; videos = []; hasMore = true }
        do { try await loadPage(page); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
        do { analytics = try await APIClient.shared.studioAnalytics(days: selectedDays) }
        catch { analytics = StudioAnalytics(metrics: [], points: []) }
    }

    func loadMore() async {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do { try await loadPage(page + 1); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    private func loadPage(_ requestedPage: Int) async throws {
        let response = try await APIClient.shared.studioVideos(page: requestedPage, limit: 10)
        let known = Set(videos.map(\.id))
        videos.append(contentsOf: response.items.filter { !known.contains($0.id) })
        page = requestedPage
        hasMore = videos.count < (response.total ?? videos.count) && !response.items.isEmpty
    }
}

struct StudioView: View {
    @EnvironmentObject private var session: SessionStore
    @StateObject private var model = StudioViewModel()
    @StateObject private var settings = Settings()
    @State private var showUpload = false

    var body: some View {
        NavigationStack {
            Group {
                if !session.isAuthenticated {
                    ContentUnavailableView(
                        "Sign in to open Studio",
                        systemImage: "rectangle.stack.badge.play",
                        description: Text("Add your Smolish cookie from the Profile tab.")
                    )
                } else if model.isLoading && model.videos.isEmpty {
                    ProgressView()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if let profile = session.profile {
                                HStack {
                                    Label("Creator braincells", systemImage: "brain.head.profile")
                                    Spacer()
                                    Text(profile.braincells.formatted(.number.notation(.compactName)))
                                        .font(.title3.bold())
                                }
                                .foregroundStyle(settings.accent)
                                .padding(16)
                                .background(settings.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                            }

                            Picker("Range", selection: $model.selectedDays) {
                                Text("7D").tag(7)
                                Text("30D").tag(30)
                                Text("90D").tag(90)
                            }
                            .pickerStyle(.segmented)
                            .glassEffect(.regular.interactive())

                            analyticsCards

                            if !model.analytics.points.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Views over time").font(.headline)
                                    Chart(model.analytics.points) { point in
                                        AreaMark(x: .value("Date", point.date), y: .value("Views", point.views))
                                            .foregroundStyle(LinearGradient(colors: [settings.accent.opacity(0.55), settings.accent.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                                        LineMark(x: .value("Date", point.date), y: .value("Views", point.views))
                                            .foregroundStyle(settings.accent).lineStyle(.init(lineWidth: 3, lineCap: .round))
                                    }
                                    .frame(height: 190)
                                    .chartYAxis { AxisMarks(position: .leading) }
                                }
                                .padding(16)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                            }

                            HStack {
                                Text("Your videos").font(.title3.bold())
                                Spacer()
                                Text("\(model.videos.count)").foregroundStyle(.secondary)
                            }

                            if model.videos.isEmpty {
                                ContentUnavailableView("No Studio videos", systemImage: "video", description: Text(model.errorMessage ?? "Your uploaded videos will appear here."))
                            } else {
                                ForEach(model.videos) { video in
                                    videoRow(video)
                                }
                                if model.hasMore {
                                    Button {
                                        Task { await model.loadMore() }
                                    } label: {
                                        HStack {
                                            if model.isLoadingMore { ProgressView() }
                                            Text(model.isLoadingMore ? "Loading…" : "Load more videos")
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(model.isLoadingMore)
                                }
                            }
                        }
                        .padding()
                    }
                    .refreshable { await model.load() }
                }
            }
            .navigationTitle("Studio")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showUpload = true } label: { Label("Upload", systemImage: "plus") }
                    Link(destination: URL(string: "https://smolish.com/studio")!) {
                        Label("Open web Studio", systemImage: "safari")
                    }
                }
            }
        }
        .task(id: session.accountRevision) { if session.isAuthenticated { await model.load() } }
        .onChange(of: model.selectedDays) { _, _ in Task { await model.load() } }
        .sheet(isPresented: $showUpload) {
            VideoUploadView {
                showUpload = false
                Task { await model.load() }
            }
        }
    }

    private var analyticsCards: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(displayMetrics) { metric in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(metric.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(formatted(metric)).font(.title2.bold()).contentTransition(.numericText())
                    }
                    .frame(width: 145, alignment: .leading)
                    .padding(16)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
                    
                    
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var displayMetrics: [AnalyticsMetric] {
        let impressions = model.videos.reduce(0) { $0 + ($1.impressionsCount ?? 0) }
        let plays = model.videos.reduce(0) { $0 + ($1.playsCount ?? 0) }
        let completions = model.videos.reduce(0) { $0 + ($1.completionsCount ?? 0) }
        let derived = [
            AnalyticsMetric(id: "views", title: "Views", value: Double(model.videos.reduce(0) { $0 + ($1.viewsCount ?? 0) }), format: .count),
            AnalyticsMetric(id: "impressions", title: "Impressions", value: Double(impressions), format: .count),
            AnalyticsMetric(id: "plays", title: "Plays", value: Double(plays), format: .count),
            AnalyticsMetric(id: "unique", title: "Unique viewers", value: Double(model.videos.reduce(0) { $0 + ($1.uniqueViewersCount ?? 0) }), format: .count),
            AnalyticsMetric(id: "completions", title: "Completions", value: Double(completions), format: .count),
            AnalyticsMetric(id: "replays", title: "Replays", value: Double(model.videos.reduce(0) { $0 + ($1.replaysCount ?? 0) }), format: .count),
            AnalyticsMetric(id: "playRate", title: "Play rate", value: impressions > 0 ? Double(plays) / Double(impressions) : 0, format: .percentage),
            AnalyticsMetric(id: "completionRate", title: "Completion rate", value: plays > 0 ? Double(completions) / Double(plays) : 0, format: .percentage),
            AnalyticsMetric(id: "likes", title: "Likes", value: Double(model.videos.reduce(0) { $0 + ($1.likesCount ?? 0) }), format: .count),
            AnalyticsMetric(id: "comments", title: "Comments", value: Double(model.videos.reduce(0) { $0 + ($1.commentsCount ?? 0) }), format: .count)
        ]
        let serverIDs = Set(model.analytics.metrics.map(\.id))
        return model.analytics.metrics + derived.filter { !serverIDs.contains($0.id) }
    }

    private func formatted(_ metric: AnalyticsMetric) -> String {
        switch metric.format {
        case .count: return metric.value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .seconds:
            let duration = Duration.seconds(metric.value)
            return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        case .percentage: return (metric.value > 1 ? metric.value / 100 : metric.value).formatted(.percent.precision(.fractionLength(1)))
        }
    }

    private func videoRow(_ video: StudioVideo) -> some View {
        HStack(spacing: 13) {
            AsyncImage(url: video.thumbnail) { image in image.resizable().scaledToFill() }
                placeholder: { Color.secondary.opacity(0.2).overlay(Image(systemName: "video.fill")) }
                .frame(width: 76, height: 100).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(video.title?.isEmpty == false ? video.title! : "Untitled video").font(.headline).lineLimit(2)
                HStack {
                    if let status = video.status { Text(status.capitalized) }
                    if let visibility = video.visibility { Text("• \(visibility.capitalized)") }
                }.font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Label((video.viewsCount ?? 0).formatted(), systemImage: "play.fill")
                    Label((video.likesCount ?? 0).formatted(), systemImage: "heart.fill")
                    Label((video.commentsCount ?? 0).formatted(), systemImage: "bubble.right.fill")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

@MainActor
final class VideoUploadViewModel: ObservableObject {
    @Published var fileURL: URL?
    @Published var title = ""
    @Published var description = ""
    @Published var visibility = "private"
    @Published var epilepsyWarning = false
    @Published var aiGenerated = false
    @Published private(set) var progress = 0.0
    @Published private(set) var isUploading = false
    @Published private(set) var visibilityReady = true
    @Published var errorMessage: String?

    func select(_ url: URL) {
        fileURL = url
        if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
    }

    func visibilityChanged() {
        visibilityReady = false
        Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            visibilityReady = true
        }
    }

    func upload() async -> Bool {
        guard let fileURL, !isUploading, visibilityReady else { return false }
        isUploading = true; errorMessage = nil; progress = 0
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() }; isUploading = false }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber else { throw APIError.invalidResponse }
            let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "video/mp4"
            let creation = try await APIClient.shared.createVideoUpload(filename: fileURL.lastPathComponent, contentType: mime, sizeBytes: size.intValue)
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            for partNumber in 1...creation.partCount {
                let data = try handle.read(upToCount: creation.partSize) ?? Data()
                let destination = try await APIClient.shared.uploadPartURL(videoID: creation.video.id, partNumber: partNumber)
                let etag = try await APIClient.shared.uploadPart(data: data, to: destination.url)
                try await APIClient.shared.acknowledgeUploadPart(videoID: creation.video.id, partNumber: partNumber, etag: etag, sizeBytes: data.count)
                progress = Double(partNumber) / Double(creation.partCount + 2)
            }
            _ = try await APIClient.shared.completeVideoUpload(videoID: creation.video.id)
            progress = Double(creation.partCount + 1) / Double(creation.partCount + 2)
            _ = try await APIClient.shared.updateVideo(
                videoID: creation.video.id, title: title, description: description, visibility: "private",
                epilepsyWarning: epilepsyWarning, aiGenerated: aiGenerated
            )
            if visibility != "private" {
                try await Task.sleep(for: .seconds(1))
                _ = try await APIClient.shared.updateVideo(
                    videoID: creation.video.id, title: title, description: description, visibility: visibility,
                    epilepsyWarning: epilepsyWarning, aiGenerated: aiGenerated
                )
            }
            progress = 1
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}

struct VideoUploadView: View {
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = VideoUploadViewModel()
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    Button { importing = true } label: {
                        Label(model.fileURL?.lastPathComponent ?? "Choose a video", systemImage: "video.badge.plus")
                    }
                    TextField("Title", text: $model.title)
                    TextField("Description", text: $model.description, axis: .vertical).lineLimit(3...6)
                }
                Section("Publishing") {
                    Picker("Visibility", selection: $model.visibility) {
                        Text("Private").tag("private")
                        Text("Unlisted").tag("unlisted")
                        Text("Public").tag("public")
                    }
                    Toggle("Flashing content warning", isOn: $model.epilepsyWarning)
                    Toggle("AI-generated", isOn: $model.aiGenerated)
                }
                if model.isUploading {
                    Section("Uploading") { ProgressView(value: model.progress); Text(model.progress, format: .percent) }
                }
                if let error = model.errorMessage { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button {
                        Task { if await model.upload() { onComplete() } }
                    } label: { Text(model.isUploading ? "Uploading…" : model.visibility == "private" ? "Save private video" : "Upload and publish").frame(maxWidth: .infinity) }
                    .disabled(model.fileURL == nil || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isUploading || !model.visibilityReady)
                }
            }
            .navigationTitle("Upload video")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.isUploading) } }
        }
        .onChange(of: model.visibility) { _, _ in model.visibilityChanged() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie]) { result in
            if case let .success(url) = result { model.select(url) }
            else if case let .failure(error) = result { model.errorMessage = error.localizedDescription }
        }
        .interactiveDismissDisabled(model.isUploading)
    }
}
