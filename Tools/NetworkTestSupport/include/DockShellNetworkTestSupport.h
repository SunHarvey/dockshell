#ifndef DOCKSHELL_NETWORK_TEST_SUPPORT_H
#define DOCKSHELL_NETWORK_TEST_SUPPORT_H

#include <stdint.h>

/// Verification-only opaque relay. It is never linked into the application.
typedef struct ds_test_proxy ds_test_proxy;

/// Listens only on IPv4 loopback with an OS-assigned port, forwarding one TCP connection.
/// Resolves target_host during this call; invoke it on a dedicated verification thread.
int ds_test_proxy_start(const char *target_host, uint16_t target_port, ds_test_proxy **result);
uint16_t ds_test_proxy_port(ds_test_proxy *proxy);
void ds_test_proxy_retain(ds_test_proxy *proxy);
void ds_test_proxy_release(ds_test_proxy *proxy);
/// Discards subsequent bytes in both directions while keeping both TCP sockets open.
void ds_test_proxy_blackhole(ds_test_proxy *proxy);
/// Wakes poll and closes only the relay's own sockets. Idempotent and nonblocking.
void ds_test_proxy_cancel(ds_test_proxy *proxy);
/// Waits for the relay worker to close all sockets. Invoke on a dedicated verification thread.
void ds_test_proxy_wait(ds_test_proxy *proxy);

#endif
