import Foundation
import Testing
@testable import PikminRuntime

struct VipSetupIdentityTests {
    private let modern = "00008110-001122334455AABB"
    private let legacy = "0123456789ABCDEF0123456789ABCDEF01234567"

    private func plist(_ object: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: format, options: 0)
    }

    private func profile(_ devices: [String]) throws -> Data {
        // A binary wrapper ensures extraction does not rely on decoding CMS as UTF-8.
        var data = Data([0x30, 0x82, 0xff, 0x00])
        data.append(try plist(["ProvisionedDevices": devices]))
        data.append(contentsOf: [0x00, 0xff, 0x30])
        return data
    }

    @Test func acceptsBothUDIDFormatsAndNormalizesCase() throws {
        #expect(VipSetupIdentity.validatedUDID(modern) == modern.lowercased())
        #expect(VipSetupIdentity.validatedUDID(legacy) == legacy.lowercased())
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            #expect(try VipSetupIdentity.udidFromWowVIPPlist(plist(["udid": modern], format: format)) == modern.lowercased())
        }
    }

    @Test func rejectsMalformedAndNonASCIIIdentity() {
        for value in ["", "device-A", "00008110-001122334455AABG", "00008110001122334455AABB",
                      "00008110-001122334455AABB0", "00008110_001122334455AABB",
                      " " + modern, modern + "\n", modern + "\0",
                      "0000811０-001122334455AABB", String(legacy.dropLast())] {
            #expect(VipSetupIdentity.validatedUDID(value) == nil)
        }
    }

    @Test func ignoresAllBundledAuthorizationSettings() throws {
        let data = try plist(["udid": modern, "pub": "attacker-key", "licenseUrl": "http://untrusted.invalid",
                              "freeMode": true, "graceDays": 365, "isVip": true] as [String: Any])
        #expect(VipSetupIdentity.udidFromWowVIPPlist(data) == modern.lowercased())
        #expect(try VipSetupIdentity.udidFromWowVIPPlist(plist(["isVip": true, "freeMode": true])) == nil)
    }

    @Test func rejectsMalformedOrWrongTypedSigningMetadata() throws {
        for object: Any in [["udid": 123], ["udid": [modern]], ["UDID": modern], [modern]] {
            #expect(try VipSetupIdentity.udidFromWowVIPPlist(plist(object)) == nil)
        }
        #expect(VipSetupIdentity.udidFromWowVIPPlist(Data("not a plist".utf8)) == nil)
        #expect(VipSetupIdentity.candidate(wowVIPPlist: nil, mobileProvision: nil) == nil)
    }

    @Test func extractsOnlyOneValidProvisionedDevice() throws {
        #expect(try VipSetupIdentity.udidFromMobileProvision(profile([modern])) == modern.lowercased())
        #expect(try VipSetupIdentity.udidFromMobileProvision(profile([legacy])) == legacy.lowercased())
        for devices in [[], [modern, legacy], [modern, modern], ["invalid"], [modern, "invalid"]] {
            #expect(try VipSetupIdentity.udidFromMobileProvision(profile(devices)) == nil)
        }
    }

    @Test func enterpriseOrWrongTypedProfileCannotIdentifyCurrentDevice() throws {
        for object: Any in [["ProvisionsAllDevices": true], ["ProvisionedDevices": modern],
                            ["ProvisionedDevices": [123]], ["ProvisionedDevices": [modern, 123]]] {
            #expect(try VipSetupIdentity.udidFromMobileProvision(plist(object)) == nil)
        }
    }

    @Test func signingHintTakesPriorityAndInvalidHintFallsBack() throws {
        let provision = try profile([legacy])
        #expect(try VipSetupIdentity.candidate(wowVIPPlist: plist(["udid": modern]), mobileProvision: provision) == modern.lowercased())
        #expect(try VipSetupIdentity.candidate(wowVIPPlist: plist(["udid": "invalid"]), mobileProvision: provision) == legacy.lowercased())
        #expect(VipSetupIdentity.candidate(wowVIPPlist: nil, mobileProvision: provision) == legacy.lowercased())
    }

    @Test func rejectsTruncatedAmbiguousAndOversizedProfiles() throws {
        let valid = try profile([modern])
        #expect(VipSetupIdentity.udidFromMobileProvision(Data("<plist><dict>".utf8)) == nil)
        #expect(VipSetupIdentity.udidFromMobileProvision(Data("</plist>".utf8)) == nil)
        #expect(VipSetupIdentity.udidFromMobileProvision(valid + valid) == nil)
        var oversized = valid
        oversized.append(Data(repeating: 0, count: VipSetupIdentity.maximumFileSize))
        #expect(VipSetupIdentity.udidFromMobileProvision(oversized) == nil)
        #expect(VipSetupIdentity.udidFromWowVIPPlist(oversized) == nil)
    }
}
