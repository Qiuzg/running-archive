import Foundation

@MainActor
final class ArchiveStore: ObservableObject {
    @Published var summary: ArchiveSummary?
    @Published var routes: [ArchiveRouteSummary] = []
    @Published var activities: [ArchiveActivity] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let api = ArchiveAPI()
    private var detailCache: [String: ArchiveRouteDetail] = [:]

    func load(force: Bool = false) async {
        if isLoading || (!force && summary != nil && !activities.isEmpty) { return }
        isLoading = true
        errorMessage = nil
        do {
            async let loadedSummary = api.summary()
            async let loadedRoutes = api.routes()
            async let loadedRuns = api.runs()
            async let loadedRaces = api.races()
            let (summary, routes, runs, races) = try await (
                loadedSummary, loadedRoutes, loadedRuns, loadedRaces
            )
            self.summary = summary
            self.routes = routes
            self.activities = (
                runs.map(ArchiveActivity.init(run:)) + races.map(ArchiveActivity.init(race:))
            ).sorted { $0.date > $1.date }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func routeDetail(id: String) async throws -> ArchiveRouteDetail {
        if let cached = detailCache[id] { return cached }
        let detail = try await api.route(id: id)
        detailCache[id] = detail
        return detail
    }

    func routeSummary(id: String?) -> ArchiveRouteSummary? {
        guard let id else { return nil }
        return routes.first { $0.id == id }
    }
}
