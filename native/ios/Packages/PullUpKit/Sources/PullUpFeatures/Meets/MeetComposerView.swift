import MapKit
import SwiftUI
import PullUpDesign
import PullUpDomain

/// Host a meet. The venue is placed by moving the map under a fixed pin, so
/// hosts pick a public place deliberately rather than sharing where they are.
struct MeetComposerView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var kind: Meet.Kind = .meet
    @State private var focus: Meet.Focus = .all
    @State private var startsAt = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var duration: Double = 3
    @State private var venueName = ""
    @State private var area = ""
    @State private var audience: Audience = .public
    @State private var capacityText = ""
    @State private var center = CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944)
    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 38.5816, longitude: -121.4944),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    ))
    @State private var isSaving = false
    @State private var error: String?

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !venueName.trimmingCharacters(in: .whitespaces).isEmpty && startsAt > .now && !isSaving
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    FieldRow(label: "Name", text: $title, prompt: "Friday night meet")
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("Kind")
                        Picker("Kind", selection: $kind) {
                            ForEach(Meet.Kind.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        Legend("For")
                        SwitchBank(Meet.Focus.allCases, selection: $focus) { $0.label }
                    }
                    VStack(alignment: .leading, spacing: Space.s) {
                        DatePicker("Starts", selection: $startsAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                        Stepper("Lasts \(Int(duration)) h", value: $duration, in: 1...96)
                    }
                    .font(ClusterFont.body())
                    venue
                    FieldRow(label: "Details", text: $details, prompt: "Rules, parking, what to bring", axis: .vertical)
                    FieldRow(label: "Capacity", text: $capacityText, prompt: "No limit", keyboard: .numberPad)
                    AudiencePicker(title: "Who can see this meet", selection: $audience, allowed: [.public, .friends])
                    ContentRulesNote(context: .meet, failure: error)
                    if kind == .trackDay {
                        NoticeStrip("Closed-course events only. Pull Up doesn't rank speed or acceleration.")
                    }
                    if let error { ErrorLine(message: error) }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.l)
            }
            .canvasBackground()
            .clusterNavigation("Host a meet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Posting" : "Post") { Task { await save() } }.disabled(!canSave)
                }
            }
        }
    }

    private var venue: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            FieldRow(label: "Venue", text: $venueName, prompt: "Public lot or business")
            FieldRow(label: "Area", text: $area, prompt: "Neighbourhood or city")
            Legend("Move the map to place the pin")
            Map(position: $position, interactionModes: [.pan, .zoom]) { UserAnnotation() }
                .mapStyle(.standard(pointsOfInterest: .including([.parking, .gasStation, .cafe, .restaurant, .store])))
                .onMapCameraChange(frequency: .onEnd) { context in center = context.region.center }
                .overlay {
                    Image(systemName: "mappin")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(ClusterColor.live)
                        .offset(y: -15)
                        .accessibilityHidden(true)
                }
                .frame(height: 220)
                .clipShape(ChamferedRectangle(cut: Radius.chamfer))
                .accessibilityLabel("Venue location map")
            Text("Pick a public place. The pin is shown to everyone who can see the meet.")
                .font(ClusterFont.body(.caption))
                .foregroundStyle(ClusterColor.inkTertiary)
        }
    }

    private func save() async {
        guard let me = app.userID else { return }
        isSaving = true
        defer { isSaving = false }
        let meet = Meet(
            hostID: me, title: title.trimmingCharacters(in: .whitespaces), details: details, kind: kind, focus: focus,
            startsAt: startsAt, endsAt: startsAt.addingTimeInterval(duration * 3600),
            venueName: venueName.trimmingCharacters(in: .whitespaces), address: area,
            latitude: center.latitude, longitude: center.longitude, visibility: audience,
            capacity: Int(capacityText.filter(\.isNumber)).flatMap { $0 > 0 ? $0 : nil }
        )
        do {
            _ = try await app.backend.createMeet(meet)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
