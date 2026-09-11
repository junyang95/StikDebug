# Third-party notices

## WLOC certificate experiment: Apple Swift packages

The tunnel's certificate-only implementation uses unmodified Apple packages:

- [swift-certificates 1.18.0](https://github.com/apple/swift-certificates/tree/1.18.0), X509.
- [swift-crypto 3.12.3](https://github.com/apple/swift-crypto/tree/3.12.3), transitive dependency.
- [swift-asn1 1.3.1](https://github.com/apple/swift-asn1/tree/1.3.1), transitive dependency.

Versions are pinned for Xcode 16.2 / Swift 6.0 compatibility. Their complete
LICENSE.txt and NOTICE.txt texts are included in the app resource
`StikDebug/Resources/WLOCAppleDependencyNotices.txt`. This section does not
claim that the experiment meets Apple distribution requirements. No Knot or
ProxyPin implementation was copied into the certificate or profile server.

## LocalDevVPN / StosVPN

Pikmin Helper's embedded local packet tunnel is based on LocalDevVPN / StosVPN
by the SideStore Team. The integration uses and modifies its
`PacketTunnelProvider` implementation.

Copyright (c) 2025 SideStore Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

Attribution must be clearly given to the original project and authors in a
prominent place. Any derived project must clearly state that it is based on or
uses code from the original project.

Redistribution, rebranding, or publishing of the entire project, or a
substantially similar copy, under the same or similar name or branding without
explicit written permission is prohibited.

Source project: https://github.com/StephenDev0/LocalDevVPN

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
