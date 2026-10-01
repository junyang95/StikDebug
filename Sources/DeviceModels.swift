import Foundation

extension StikJIT {
    public struct InstalledApplication: Sendable {
        public let bundleIdentifier: String
        public let name: String
        public let isDebuggable: Bool
        public let iconPNG: Data?

        public init(bundleIdentifier: String, name: String, isDebuggable: Bool, iconPNG: Data? = nil) {
            self.bundleIdentifier = bundleIdentifier
            self.name = name
            self.isDebuggable = isDebuggable
            self.iconPNG = iconPNG
        }
    }

    public struct ProvisioningProfile: Sendable {
        public let id: String
        public let name: String
        public let appIdentifier: String
        public let expirationDate: Date?
        public let data: Data
    }
}
