import Foundation

/// App Store media capture: the labelled demo backend, presented without its
/// on-screen demo labels and without Pull Up Pro, so screenshots and app
/// previews show the app as people will see it. Used only by the Store media
/// workflow (.github/workflows/store-media.yml) on the simulator.
///
/// Compiled out of Release builds: there it is always false, whatever the
/// launch arguments, so a shipped app always labels demo mode. It also needs
/// `-PullUpDemo`, so it never touches sign-in or a real backend.
public enum StoreCapture {
    public static let isActive: Bool = {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-PullUpDemo") && args.contains("-PullUpStoreCapture")
        #else
        return false
        #endif
    }()
}
