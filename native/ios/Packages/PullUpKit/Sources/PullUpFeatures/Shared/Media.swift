import SwiftUI
import UIKit
import PullUpData
import PullUpDesign
import PullUpDomain

/// Loads an image from private storage via a short-lived signed URL.
struct StorageImage<Placeholder: View>: View {
    @Environment(AppModel.self) private var app
    let bucket: MediaBucket
    let path: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var url: URL?

    var body: some View {
        ZStack {
            if let url {
                if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                } else {
                    AsyncImage(url: url, transaction: Transaction(animation: Motion.quick)) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: contentMode)
                        } else {
                            placeholder()
                        }
                    }
                }
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            guard let path else {
                url = nil
                return
            }
            url = await app.backend.mediaURL(bucket, path: path)
        }
    }
}

/// A vehicle's cover photo, or its silhouette on an identity-tinted plate.
struct VehicleArtwork: View {
    let vehicle: Vehicle?

    var body: some View {
        if let vehicle {
            StorageImage(bucket: .vehicleMedia, path: vehicle.coverPhotoPath) {
                VehiclePlaceholder(style: vehicle.bodyStyle, identity: vehicle.identityColor)
            }
            .accessibilityHidden(true)
        } else {
            GuestArtwork()
        }
    }
}

/// Artwork for the guest option: a dashed outline instead of a vehicle.
struct GuestArtwork: View {
    var body: some View {
        ZStack {
            Rectangle().fill(ClusterColor.plateRaised)
            VehicleSilhouette(.other, color: ClusterColor.inkTertiary, lineWidth: 1.2)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .opacity(0.8)
        }
        .accessibilityHidden(true)
    }
}

/// Initials on a chamfered plate; the photo when one exists.
struct Avatar: View {
    let name: String
    let path: String?
    var size: CGFloat = 36

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        StorageImage(bucket: .avatars, path: path) {
            ZStack {
                ClusterColor.plateRaised
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(ClusterColor.inkSecondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
