#include "idevice.h"

struct IdeviceFfiError *pikmin_pairable_host_accept(
    const char *name,
    const char *model,
    uint16_t port,
    void (*pin_callback)(const char *pin, void *context),
    void *pin_context,
    PairableHostListeningCallback listening_callback,
    void *listening_context,
    PairableHostConnectedCallback connected_callback,
    void *connected_context,
    uint8_t *out_host_alt_irk,
    struct RpPairingFileHandle **out_pairing_file
) {
    return pairable_host_accept(
        name, model, port,
        pin_callback, pin_context,
        listening_callback, listening_context,
        connected_callback, connected_context,
        out_host_alt_irk, out_pairing_file
    );
}

void pikmin_pairing_error_free(struct IdeviceFfiError *error) {
    idevice_error_free(error);
}

struct IdeviceFfiError *pikmin_pairing_file_write(
    struct RpPairingFileHandle *handle,
    const char *path
) {
    return rp_pairing_file_write(handle, path);
}

void pikmin_pairing_file_free(struct RpPairingFileHandle *handle) {
    rp_pairing_file_free(handle);
}
