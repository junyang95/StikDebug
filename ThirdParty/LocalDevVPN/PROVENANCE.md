# LocalDevVPN attribution

JIT启动器 uses code from [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN),
originally created by Stossy11 / SideStore Team and maintained by Coxson Engineering
and contributors. The imported version is commit `af3fd69` (Add japanese translation
(#27)), as checked out in the local LocalDevVPN repository during integration.

Imported files:

- `LocalDevVPN/Constants.swift` → `Shared/TunnelConstants.swift` (unchanged).
- `TunnelProv/CIDRValidator.swift` → `Shared/CIDRValidator.swift` (unchanged).
- `TunnelProv/PacketTunnelProvider.swift` → `Tunnel/PacketTunnelProvider.swift`.

The packet provider retains LocalDevVPN's IPv4 source/destination reflection and
host-only route behavior. Integration changes validate configuration, stop packet
processing when a tunnel session ends, guard packet bounds, and avoid unaligned
word access. The app's VPN manager is a new implementation that controls only the
integrated extension and always uses LocalDevVPN's default endpoints, matching
StikJIT's device address.

`LICENSE` is the upstream StosVPN license, including attribution and branding
conditions; `LICENSE-old` is the historical upstream MIT license. Both are retained
verbatim. JIT启动器 is a separately named integration and is not the official
LocalDevVPN app. Its About screen and repository documentation also credit the
original project.
