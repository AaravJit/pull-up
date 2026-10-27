import Foundation
import PullUpDomain
import PullUpTelemetry

/// Fixed demo content. People and vehicles come from the original Pull Up
/// design prototype so the native app and the old Expo app tell the same
/// story. All of it is fictional.
enum DemoSeed {
    static let meID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let mayaID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let dreID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let kenjiID = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    static let gearboxID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    /// Someone the demo driver doesn't follow, so their message is a request.
    static let samID = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!

    static let mayaConversationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!
    static let kenjiConversationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!
    static let samConversationID = UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!

    static let bmwID = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
    static let gsxrID = UUID(uuidString: "00000000-0000-4000-8000-0000000000a2")!
    static let rx7ID = UUID(uuidString: "00000000-0000-4000-8000-0000000000a3")!

    static func make(signedIn: Bool, emptyGarage: Bool, now: Date) -> DemoBackend.State {
        var s = DemoBackend.State()
        s.me = signedIn ? meID : nil

        func page(_ id: UUID, _ username: String, _ name: String, bio: String = "", layout: ProfilePresentation.Layout = .showcase, featured: UUID? = nil, organizer: Bool = false) -> ProfilePage {
            ProfilePage(
                profile: Profile(id: id, username: username, displayName: name, bio: bio, countryCode: "US", regionCode: "US-CA",
                                 presentation: ProfilePresentation(layout: layout, featuredVehicleID: featured)),
                isVerifiedOrganizer: organizer
            )
        }
        s.profiles = [
            meID: page(meID, "you", "Demo Driver", bio: "Midtown lots and backroads. Slow build, loud enough.", featured: rx7ID),
            mayaID: page(mayaID, "maya.s15", "Maya", bio: "S15 Spec-R. Night Shift."),
            dreID: page(dreID, "dre.mt", "Dre", bio: "Two wheels, no plans."),
            kenjiID: page(kenjiID, "kenji.dc2", "Kenji", bio: "Type R or nothing."),
            gearboxID: page(gearboxID, "gearbox.collective", "Gearbox Collective", bio: "Sacramento meets since 2019.", organizer: true),
            samID: page(samID, "sam.ek9", "Sam", bio: "EK9, Sunday mornings only."),
        ]
        s.follows = [[meID, mayaID], [mayaID, meID], [meID, kenjiID], [kenjiID, meID], [meID, dreID], [meID, gearboxID]]

        if !emptyGarage {
            s.vehicles = [
                Vehicle(id: rx7ID, ownerID: meID, kind: .car, bodyStyle: .coupe, make: "Mazda", model: "RX-7", year: 1994, trim: "FD3S",
                        nickname: "", mileage: 88_400, summary: "13B-REW, single turbo conversion in progress.", visibility: .public, identityColor: .redline, position: 0),
                Vehicle(id: bmwID, ownerID: meID, kind: .car, bodyStyle: .sedan, make: "BMW", model: "320i xDrive", year: 2014, trim: "F30 · N20",
                        nickname: "Daily", mileage: 112_000, summary: "Winter car. Stock and staying that way.", visibility: .friends, identityColor: .gulf, position: 1),
                Vehicle(id: gsxrID, ownerID: meID, kind: .motorcycle, bodyStyle: .sport, make: "Suzuki", model: "GSX-R750", year: 2001, trim: "K1",
                        mileage: 31_200, summary: "Yoshimura slip-on, frame sliders.", visibility: .public, identityColor: .sodium, position: 2),
                Vehicle(ownerID: mayaID, kind: .car, bodyStyle: .coupe, make: "Nissan", model: "Silvia", year: 2003, trim: "S15 Spec-R", visibility: .public, identityColor: .ultraviolet),
                Vehicle(ownerID: dreID, kind: .motorcycle, bodyStyle: .naked, make: "Yamaha", model: "MT-09", year: 2019, trim: "SP", visibility: .public, identityColor: .gulf),
                Vehicle(ownerID: kenjiID, kind: .car, bodyStyle: .hatchback, make: "Acura", model: "Integra Type R", year: 1998, trim: "DC2", visibility: .public, identityColor: .britishGreen),
            ]
            s.mods = [
                VehicleModification(vehicleID: rx7ID, category: .forcedInduction, title: "Single turbo conversion", brand: "Garrett G30-770", installedOn: now.addingTimeInterval(-86_400 * 20)),
                VehicleModification(vehicleID: rx7ID, category: .suspension, title: "Coilovers", brand: "Ohlins Road & Track", installedOn: now.addingTimeInterval(-86_400 * 140)),
                VehicleModification(vehicleID: rx7ID, category: .wheels, title: "17×9 +45", brand: "Volk TE37"),
                VehicleModification(vehicleID: rx7ID, category: .exhaust, title: "Cat-back", brand: "Knight Sports"),
                VehicleModification(vehicleID: gsxrID, category: .exhaust, title: "Slip-on", brand: "Yoshimura R-77"),
            ]
        }

        // Drives with real synthetic tracks, so statistics and maps are
        // computed by the telemetry engine rather than typed in.
        let routes: [(UUID?, String, TimeInterval, [Double])] = [
            (rx7ID, "Folsom backroads", 86_400 * 1, DemoTracks.backroadProfile),
            (bmwID, "Commute", 86_400 * 2, DemoTracks.commuteProfile),
            (gsxrID, "Delta loop", 86_400 * 5, Array(DemoTracks.backroadProfile.reversed())),
        ]
        if !emptyGarage {
            for (index, route) in routes.enumerated() {
                let start = now.addingTimeInterval(-route.2)
                let track = DemoTracks.track(start: start, speeds: route.3, headingSeed: Double(index))
                let engine = TelemetryEngine.replay(track, startedAt: start)
                var drive = Drive(id: UUID(), ownerID: meID, vehicleID: route.0, title: route.1,
                                  summary: engine.summary(endedAt: track.last?.timestamp ?? start), visibility: .friends)
                drive.validationStatus = .validated
                s.drives.append(drive)
                s.tracks[drive.id] = track
            }
        }

        let tonight = Calendar.current.date(bySettingHour: 21, minute: 15, second: 0, of: now) ?? now
        s.meets = [
            Meet(hostID: gearboxID, title: "Sac Nights", details: "Monthly night meet. No burnouts, no revving, respect the lot.",
                 kind: .meet, startsAt: tonight, endsAt: tonight.addingTimeInterval(3 * 3_600), venueName: "Sutter Lot",
                 address: "Midtown, Sacramento", latitude: 38.5735, longitude: -121.4765, goingCount: 38, interestedCount: 61),
            Meet(hostID: gearboxID, title: "Cars & Coffee Arden", kind: .meet, startsAt: nextWeekday(7, hour: 7, minute: 30, from: now),
                 endsAt: nextWeekday(7, hour: 10, minute: 0, from: now), venueName: "Arden Fair", address: "North Sacramento",
                 latitude: 38.6017, longitude: -121.4256, goingCount: 112, interestedCount: 240),
            Meet(hostID: dreID, title: "Elk Grove Bike Night", kind: .ride, focus: .motorcycles, startsAt: tonight.addingTimeInterval(1_800),
                 endsAt: tonight.addingTimeInterval(4 * 3_600), venueName: "Laguna Town Hall", latitude: 38.4250, longitude: -121.4240, goingCount: 40),
            Meet(hostID: mayaID, title: "Hwy 49 Gold Country Cruise", details: "Easy pace, regroup at every town. Fuel in Placerville.",
                 kind: .cruise, startsAt: nextWeekday(1, hour: 9, minute: 0, from: now), endsAt: nextWeekday(1, hour: 15, minute: 0, from: now),
                 venueName: "Auburn Park & Ride", latitude: 38.8966, longitude: -121.0769, capacity: 30, goingCount: 18),
            Meet(hostID: gearboxID, title: "Thunderhill Open Track", details: "Closed course. Helmets, tech inspection and waiver required.",
                 kind: .trackDay, startsAt: nextWeekday(7, hour: 8, minute: 0, from: now).addingTimeInterval(7 * 86_400),
                 endsAt: nextWeekday(7, hour: 17, minute: 0, from: now).addingTimeInterval(7 * 86_400), venueName: "Thunderhill Raceway Park",
                 address: "Willows, CA", latitude: 39.5393, longitude: -122.3312, capacity: 60, goingCount: 44),
        ]

        s.posts = [
            Post(authorID: mayaID, kind: .build, caption: "Finally dialed the alignment. 2.5° front camber and it feels like a different car.",
                 visibility: .public, createdAt: now.addingTimeInterval(-2_400), likeCount: 48, commentCount: 0),
            Post(authorID: meID, kind: .build, caption: "Turbo is in. Tuning next week. No dyno numbers until it's right.",
                 vehicleID: rx7ID, visibility: .public, createdAt: now.addingTimeInterval(-7_200), likeCount: 112, likedByMe: false),
            Post(authorID: dreID, kind: .moment, caption: "Sunrise on the levee before the wind picked up.",
                 visibility: .public, createdAt: now.addingTimeInterval(-26_000), likeCount: 31),
            Post(authorID: gearboxID, kind: .meet, caption: "Sac Nights is on tonight. Same rules: no burnouts, no revving, leave quietly.",
                 visibility: .public, createdAt: now.addingTimeInterval(-40_000), likeCount: 220),
            Post(authorID: kenjiID, kind: .moment, caption: "Valve adjust done. B18C sounds right again.",
                 visibility: .public, createdAt: now.addingTimeInterval(-90_000), likeCount: 27),
        ]
        if let post = s.posts.first {
            s.comments = [
                Comment(postID: post.id, authorID: kenjiID, body: "Told you the rear toe was the problem", createdAt: now.addingTimeInterval(-2_000)),
                Comment(postID: post.id, authorID: meID, body: "Bring it to Sac Nights", createdAt: now.addingTimeInterval(-1_800)),
            ]
        }

        s.notifications = [
            AppNotification(id: UUID(), kind: .follow, actor: ProfileStub(id: dreID, username: "dre.mt", displayName: "Dre"), createdAt: now.addingTimeInterval(-600)),
            AppNotification(id: UUID(), kind: .like, actor: ProfileStub(id: mayaID, username: "maya.s15", displayName: "Maya"), postID: s.posts[1].id, createdAt: now.addingTimeInterval(-1_200)),
            AppNotification(id: UUID(), kind: .meetUpdated, actor: ProfileStub(id: gearboxID, username: "gearbox.collective", displayName: "Gearbox Collective"), meetID: s.meets[0].id, createdAt: now.addingTimeInterval(-5_000)),
            AppNotification(id: UUID(), kind: .driveValidated, actor: nil, driveID: s.drives.first?.id, createdAt: now.addingTimeInterval(-80_000), readAt: now.addingTimeInterval(-70_000)),
        ]
        seedMessages(&s, now: now)
        s.zones = [PrivacyZone(label: "Home", center: Coordinate(latitude: 38.5650, longitude: -121.4700), radiusMeters: 300)]
        return s
    }

    /// Three conversations: an unread one with a shared meet, a read one that
    /// started from "Message owner" on the GSX-R750, and a message request.
    static func seedMessages(_ s: inout DemoBackend.State, now: Date) {
        func at(_ secondsAgo: TimeInterval) -> Date { now.addingTimeInterval(-secondsAgo) }
        let cruise = s.meets.first { $0.hostID == mayaID }
        s.conversations = [
            DemoBackend.Conversation(id: mayaConversationID, peer: mayaID, myReadAt: at(9_000), peerReadAt: at(7_200)),
            DemoBackend.Conversation(id: kenjiConversationID, peer: kenjiID, myReadAt: at(72_000), peerReadAt: at(68_000), repliedOnce: true),
            DemoBackend.Conversation(id: samConversationID, peer: samID, myState: .request, repliedOnce: true),
        ]
        s.messages = [
            DirectMessage(conversationID: mayaConversationID, senderID: mayaID, body: "Gold Country cruise on Sunday. Easy pace, regroup at every town.", createdAt: at(10_800)),
            DirectMessage(conversationID: mayaConversationID, senderID: mayaID, body: "", shared: cruise.map { SharedRef(kind: .meet, id: $0.id) }, createdAt: at(10_790)),
            DirectMessage(conversationID: mayaConversationID, senderID: meID, body: "I'm in if the RX-7 is back together by then", createdAt: at(9_000),
                    reactions: [MessageReaction(userID: mayaID, emoji: "🔥")]),
            DirectMessage(conversationID: mayaConversationID, senderID: mayaID, body: "Bring the BMW if not. Nobody minds a daily 😅", createdAt: at(2_400)),

            DirectMessage(conversationID: kenjiConversationID, senderID: kenjiID, body: "Is the GSX-R750 for sale by any chance?",
                    shared: SharedRef(kind: .vehicle, id: gsxrID), createdAt: at(86_400)),
            DirectMessage(conversationID: kenjiConversationID, senderID: meID, body: "Not selling, but come see the slip-on at Sac Nights.", createdAt: at(82_800)),
            DirectMessage(conversationID: kenjiConversationID, senderID: kenjiID, body: "Deal.", createdAt: at(79_200),
                    reactions: [MessageReaction(userID: meID, emoji: "👍")]),
            DirectMessage(conversationID: kenjiConversationID, senderID: meID, body: "Bring the DC2 too", createdAt: at(72_000)),

            DirectMessage(conversationID: samConversationID, senderID: samID, body: "Saw your FD at Cars & Coffee. Who did the turbo kit?", createdAt: at(3_000)),
            DirectMessage(conversationID: samConversationID, senderID: samID, body: "No rush, just curious", createdAt: at(2_950)),
        ]
    }

    static func nextWeekday(_ weekday: Int, hour: Int, minute: Int, from date: Date) -> Date {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = minute
        return Calendar.current.nextDate(after: date, matching: components, matchingPolicy: .nextTime) ?? date
    }

    static func leaderboard(_ query: LeaderboardQuery, includeMe: Bool) -> [LeaderboardEntry] {
        let people: [(UUID, String, String, String, VehicleKind)] = [
            (mayaID, "maya.s15", "Maya", "2003 Nissan Silvia", .car),
            (kenjiID, "kenji.dc2", "Kenji", "1998 Acura Integra Type R", .car),
            (dreID, "dre.mt", "Dre", "2019 Yamaha MT-09", .motorcycle),
            (UUID(uuidString: "00000000-0000-4000-8000-000000000010")!, "levee.runner", "Priya", "2017 Honda Civic Type R", .car),
            (UUID(uuidString: "00000000-0000-4000-8000-000000000011")!, "golden.hour", "Marcus", "2021 Toyota GR Supra", .car),
            (UUID(uuidString: "00000000-0000-4000-8000-000000000012")!, "two.stroke", "Lena", "2006 KTM 300 EXC", .motorcycle),
        ]
        guard !query.metric.isPerformance else { return [] } // no verified track sessions in the demo
        let base: [Double]
        switch query.metric {
        case .distance: base = [1_284_000, 1_102_500, 980_200, 760_000, 512_300, 220_000]
        case .drives: base = [42, 37, 31, 22, 19, 9]
        case .exploration: base = [318, 290, 244, 201, 133, 88]
        case .community: base = [24, 19, 15, 11, 8, 4]
        case .zeroToSixty, .topSpeed: base = []
        }
        let scale: Double = switch query.period {
        case .week: 0.08
        case .month: 0.3
        case .allTime: 1
        }
        var entries = zip(people, base).filter { query.vehicleKind == nil || $0.0.4 == query.vehicleKind }.map { person, value in
            LeaderboardEntry(rank: 0, user: ProfileStub(id: person.0, username: person.1, displayName: person.2),
                             value: (value * scale).rounded(), vehicleTitle: person.3)
        }
        if includeMe, query.vehicleKind != .motorcycle {
            let me = StoreCapture.isActive ? ProfileStub(id: meID, username: captureUsername, displayName: captureDisplayName)
                : ProfileStub(id: meID, username: "you", displayName: "Demo Driver")
            entries.append(LeaderboardEntry(rank: 0, user: me,
                                            value: (base[2] * 0.93 * scale).rounded(), vehicleTitle: "1994 Mazda RX-7", isMe: true))
        }
        entries.sort { $0.value > $1.value }
        for i in entries.indices { entries[i].rank = i + 1 }
        return entries
    }
}

extension DemoSeed {
    static let captureUsername = "alex.fd3s"
    static let captureDisplayName = "Alex"

    /// Store media capture (StoreCapture, debug builds only): the demo
    /// driver gets an ordinary fictional name instead of "Demo Driver", and
    /// meets held at named real businesses or circuits move to generic,
    /// made-up venues. Everything else stays as seeded.
    static func applyStoreCapture(to s: inout DemoBackend.State) {
        s.profiles[meID]?.profile.username = captureUsername
        s.profiles[meID]?.profile.displayName = captureDisplayName
        let venues: [String: (title: String?, venue: String, address: String?)] = [
            "Cars & Coffee Arden": ("Saturday Cars & Coffee", "Riverside Lot B", "North Sacramento"),
            "Elk Grove Bike Night": (nil, "Laguna Plaza", nil),
            "Thunderhill Open Track": ("Valley Open Track Day", "Valley Motorsport Park", "Willows, CA"),
        ]
        for i in s.meets.indices {
            guard let change = venues[s.meets[i].title] else { continue }
            if let title = change.title { s.meets[i].title = title }
            s.meets[i].venueName = change.venue
            if let address = change.address { s.meets[i].address = address }
        }
    }
}

/// Synthetic but physically plausible tracks around Sacramento.
public enum DemoTracks {
    /// ~1 Hz speed profile (m/s): launch, cruise, corners, stops.
    static let backroadProfile: [Double] = {
        var v: [Double] = Array(repeating: 0, count: 6)
        for t in 1...7 { v.append(Double(t) * 4.1) }                 // spirited launch to ~64 mph
        v += Array(repeating: 27, count: 50)
        for t in 0..<12 { v.append(27 - Double(t) * 1.2) }
        v += Array(repeating: 13, count: 30)                          // town
        v += Array(repeating: 0, count: 25)                           // stop sign + light
        for t in 1...10 { v.append(Double(t) * 2.4) }
        v += (0..<240).map { 22 + 5 * sin(Double($0) / 14) }          // twisty section
        for t in 0..<10 { v.append(24 - Double(t) * 2.4) }
        v += Array(repeating: 0, count: 8)
        return v
    }()

    static let commuteProfile: [Double] = {
        var v: [Double] = Array(repeating: 0, count: 5)
        for _ in 0..<6 {
            for t in 1...8 { v.append(Double(t) * 1.8) }
            v += Array(repeating: 14.5, count: 45)
            for t in 0..<8 { v.append(14.5 - Double(t) * 1.8) }
            v += Array(repeating: 0, count: 30)
        }
        v += (0..<180).map { 29 + 2 * sin(Double($0) / 20) }          // freeway
        return v
    }()

    public static func track(start: Date, speeds: [Double], headingSeed: Double, origin: Coordinate = Coordinate(latitude: 38.5816, longitude: -121.4944)) -> [LocationSample] {
        var lat = origin.latitude
        var lon = origin.longitude
        var heading = headingSeed * 1.3
        var altitude = 18.0
        var samples: [LocationSample] = []
        let metersPerDegree = 111_195.0
        for (i, speed) in speeds.enumerated() {
            if i > 0 {
                let distance = (speeds[i - 1] + speed) / 2
                heading += 0.035 * sin(Double(i) / 23 + headingSeed)
                lat += distance * cos(heading) / metersPerDegree
                lon += distance * sin(heading) / (metersPerDegree * cos(lat * .pi / 180))
                altitude += 0.6 * sin(Double(i) / 40 + headingSeed)
            }
            let jitter = Double((i * 7919) % 5) * 0.6
            samples.append(LocationSample(
                timestamp: start.addingTimeInterval(Double(i)), latitude: lat, longitude: lon, altitude: altitude,
                horizontalAccuracy: 4 + jitter, verticalAccuracy: 6, speed: speed, speedAccuracy: 0.4 + jitter / 10, course: (heading * 180 / .pi).truncatingRemainder(dividingBy: 360)
            ))
        }
        return samples
    }

    /// A drive for the live-dashboard demo replay.
    public static func liveReplay(start: Date) -> [LocationSample] {
        track(start: start, speeds: backroadProfile, headingSeed: 0.4)
    }
}
