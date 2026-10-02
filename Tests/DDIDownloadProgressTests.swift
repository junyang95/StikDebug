import Foundation

@main
enum DDIDownloadProgressTests {
    static func main() {
        let payload = "ddi|downloading|mirror|Image.dmg|1024|4096"
        let progress = DDIDownloadProgress(payload)
        precondition(progress?.received == 1024 && progress?.expected == 4096)
        precondition(progress?.source == "mirror" && progress?.file == "Image.dmg")
        for phase in ["fallback", "verifying", "committing"] {
            precondition(DDIDownloadProgress("ddi|\(phase)|upstream|Image.dmg.root_hash|229|229")?.phase == phase)
        }
        let invalid = [
            "DDI ready", "ddi|downloading|mirror|Image.dmg|1024",
            "ddi|unknown|mirror|Image.dmg|0|1", "ddi|downloading|other|Image.dmg|0|1",
            "ddi|downloading|mirror|../../device-identifier|0|1",
            "ddi|downloading|mirror|Image.dmg|-1|1",
            "ddi|downloading|mirror|Image.dmg|0|0",
            "ddi|downloading|mirror|Image.dmg|2|1",
            "ddi|downloading|mirror|Image.dmg|0|999999999999999999999999",
            "ddi|downloading|mirror|Image.dmg|NaN|1"
        ]
        for status in invalid { precondition(DDIDownloadProgress(status) == nil, status) }
        print("15 DDI progress checks passed")
    }
}
