# Pairable-host shim

StikDebug's original `libidevice_ffi.a` includes services that are not
present in Locus's smaller archive. Replacing it would remove DDI, debug,
process, profile, SpringBoard, and syslog symbols.

`build.sh` relocates Locus's archive into one object and hides every global
symbol except four prefixed pairing functions. This lets the app keep its
original full idevice library while linking the iOS 27 pairable-host flow
without duplicate Rust runtimes or duplicate public C symbols.

Regenerate the checked-in archive with:

```sh
Tools/PairableHostShim/build.sh \
  /path/to/Locus/Vendor/idevice/libidevice_ffi.a \
  /path/to/Locus/Vendor/idevice/idevice.h \
  StikDebug/idevice/libpairable_host.a
```

The Locus archive currently targets iOS 18. The entry points are only invoked
behind the app's iOS 27 availability check.
