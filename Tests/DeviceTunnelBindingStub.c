#include "idevice.h"
#include <string.h>

static int counts[16], tunnel_mode, identity_mode;
static uintptr_t adapter_id, handshake_id;
static char actual_udid[128] = "00008110-000A010203040506";
void binding_test_reset(void) { memset(counts, 0, sizeof(counts)); tunnel_mode = identity_mode = 0; }
int binding_test_count(int event) { return counts[event]; }
void binding_test_tunnel_mode(int mode) { tunnel_mode = mode; }
void binding_test_identity_mode(int mode) { identity_mode = mode; }
void binding_test_udid(const char *value) { snprintf(actual_udid, sizeof(actual_udid), "%s", value); }
uintptr_t binding_test_adapter(void) { return adapter_id; }
uintptr_t binding_test_handshake(void) { return handshake_id; }
static IdeviceFfiError *failure(void) {
    IdeviceFfiError *error = calloc(1, sizeof(*error)); error->code = 23; error->message = "test transport failure"; return error;
}
void idevice_error_free(IdeviceFfiError *error) { free(error); }
IdeviceFfiError *rp_pairing_file_read(const char *path, RpPairingFileHandle **out) { *out = (void *)1; return NULL; }
void rp_pairing_file_free(RpPairingFileHandle *handle) { counts[11]++; }
IdeviceFfiError *tunnel_create_rppairing(const idevice_sockaddr *addr, idevice_socklen_t len,
    const char *host, RpPairingFileHandle *pairing, const char *(*pin)(void *), void *context,
    AdapterHandle **adapter, RsdHandshakeHandle **handshake) {
    counts[0]++;
    if (tunnel_mode == 1) return failure();
    adapter_id += 2; handshake_id = adapter_id + 1;
    *adapter = (void *)adapter_id;
    if (tunnel_mode == 2) return failure();
    if (tunnel_mode != 3) *handshake = (void *)handshake_id;
    return NULL;
}
void adapter_free(AdapterHandle *handle) { counts[1]++; }
void rsd_handshake_free(RsdHandshakeHandle *handle) { counts[2]++; }
IdeviceFfiError *lockdownd_connect_rsd(AdapterHandle *adapter, RsdHandshakeHandle *handshake, LockdowndClientHandle **client) {
    counts[3]++;
    if ((uintptr_t)adapter == adapter_id && (uintptr_t)handshake == handshake_id) counts[12]++;
    if (identity_mode == 1) return failure();
    if (identity_mode != 2) *client = (void *)3;
    return NULL;
}
IdeviceFfiError *lockdownd_get_value(LockdowndClientHandle *client, const char *key, const char *domain, plist_t *out) {
    counts[4]++;
    if (!key || strcmp(key, "UniqueDeviceID") || domain) abort();
    if (identity_mode == 3) return failure();
    if (identity_mode == 4) return NULL;
    *out = identity_mode == 5 ? plist_new_uint(9) : plist_new_string(actual_udid);
    return NULL;
}
void lockdownd_client_free(LockdowndClientHandle *client) { counts[5]++; }
IdeviceFfiError *app_service_connect_rsd(AdapterHandle *adapter, RsdHandshakeHandle *handshake, AppServiceHandle **client) {
    counts[6]++; *client = (void *)4; return NULL;
}
void app_service_free(AppServiceHandle *client) {}
IdeviceFfiError *app_service_send_signal(AppServiceHandle *client, uint32_t pid, uint32_t signal, SignalResponseC **out) {
    counts[7]++; counts[8] = signal; counts[13] = pid;
    *out = calloc(1, sizeof(**out)); (*out)->pid = pid; (*out)->signal = signal; return NULL;
}
void app_service_free_signal_response(SignalResponseC *response) { free(response); }
IdeviceFfiError *remote_server_connect_rsd(AdapterHandle *adapter, RsdHandshakeHandle *handshake, RemoteServerHandle **server) {
    counts[14]++; *server = (void *)5; return NULL;
}
void remote_server_free(RemoteServerHandle *server) {}
IdeviceFfiError *location_simulation_new(RemoteServerHandle *server, LocationSimulationHandle **client) { *client = (void *)6; return NULL; }
void location_simulation_free(LocationSimulationHandle *client) {}
IdeviceFfiError *location_simulation_clear(LocationSimulationHandle *client) { counts[9]++; return NULL; }
IdeviceFfiError *location_simulation_set(LocationSimulationHandle *client, double lat, double lon) { counts[10]++; return NULL; }
