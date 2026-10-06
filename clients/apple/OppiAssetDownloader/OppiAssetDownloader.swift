import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Lets the system download Oppi's Apple-hosted asset packs (Nerd Font
/// symbols) around install and update, while the app is not running. The
/// default StoreDownloaderExtension behavior follows each pack's manifest
/// policy; the app shares `group.oppi` with this extension.
@main
struct OppiAssetDownloader: StoreDownloaderExtension {}
