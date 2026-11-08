import Foundation

@main
enum DDIDownloadProgressTests {
    static func main() {
        var checks = 0
        let progress = DDIDownloadProgress("ddi|copying|bundle|Image.dmg|1024|4096")
        precondition(progress?.received == 1024 && progress?.expected == 4096)
        precondition(progress?.source == "bundle" && progress?.file == "Image.dmg")
        checks += 1
        for phase in ["copying", "verifying", "committing"] {
            precondition(DDIDownloadProgress("ddi|\(phase)|bundle|Image.dmg.root_hash|229|229")?.phase == phase)
            checks += 1
        }
        for file in ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache", "Image.dmg.cryptex_info", "Image.dmg.root_hash"] {
            precondition(DDIDownloadProgress("ddi|copying|bundle|\(file)|0|1")?.file == file)
            checks += 1
        }
        let invalid = [
            "DDI ready", "ddi|copying|bundle|Image.dmg|1024",
            "ddi|unknown|bundle|Image.dmg|0|1", "ddi|copying|other|Image.dmg|0|1",
            "ddi|copying|bundle|../../device-identifier|0|1",
            "ddi|copying|bundle|Image.dmg|-1|1",
            "ddi|copying|bundle|Image.dmg|0|0",
            "ddi|copying|bundle|Image.dmg|2|1",
            "ddi|copying|bundle|Image.dmg|0|999999999999999999999999",
            "ddi|copying|bundle|Image.dmg|NaN|1",
            // Removed network phases and sources must never be displayed.
            "ddi|downloading|bundle|Image.dmg|0|1",
            "ddi|fallback|bundle|Image.dmg|0|1",
            "ddi|copying|mirror|Image.dmg|0|1",
            "ddi|verifying|upstream|Image.dmg|1|1",
            "ddi|copying|https://example.com|Image.dmg|0|1",
            "ddi|copying|bundle|Image.dmg|0|1|unexpected"
        ]
        for status in invalid {
            precondition(DDIDownloadProgress(status) == nil, status)
            checks += 1
        }
        print("\(checks) bundled DDI progress checks passed")
    }
}
