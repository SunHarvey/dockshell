#include "DockShellNetworkTestSupport.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define DS_TEST_PROXY_CAPACITY 65536

struct ds_test_proxy {
    pthread_mutex_t lock;
    pthread_cond_t completed;
    unsigned references;
    int listener, wake_read, wake_write;
    int canceled, blackhole, finished;
    uint16_t port;
    struct sockaddr_storage target;
    socklen_t target_length;
};

struct proxy_buffer {
    unsigned char bytes[DS_TEST_PROXY_CAPACITY];
    size_t count;
};

static int configure(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ||
        fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) return errno;
    return 0;
}

static int configure_socket(int fd) {
    int error = configure(fd), enabled = 1;
    if (!error && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) error = errno;
    return error;
}

static void wake(ds_test_proxy *proxy) {
    unsigned char value = 1;
    ssize_t ignored = write(proxy->wake_write, &value, 1);
    (void)ignored;
}

void ds_test_proxy_retain(ds_test_proxy *proxy) {
    pthread_mutex_lock(&proxy->lock);
    ++proxy->references;
    pthread_mutex_unlock(&proxy->lock);
}

void ds_test_proxy_release(ds_test_proxy *proxy) {
    pthread_mutex_lock(&proxy->lock);
    int last = --proxy->references == 0;
    pthread_mutex_unlock(&proxy->lock);
    if (last) {
        if (proxy->listener >= 0) close(proxy->listener);
        if (proxy->wake_read >= 0) close(proxy->wake_read);
        if (proxy->wake_write >= 0) close(proxy->wake_write);
        pthread_cond_destroy(&proxy->completed);
        pthread_mutex_destroy(&proxy->lock);
        free(proxy);
    }
}

static int state(ds_test_proxy *proxy, int *blackhole) {
    pthread_mutex_lock(&proxy->lock);
    int canceled = proxy->canceled;
    *blackhole = proxy->blackhole;
    pthread_mutex_unlock(&proxy->lock);
    return canceled;
}

static void drain_wake(ds_test_proxy *proxy) {
    unsigned char bytes[128];
    while (read(proxy->wake_read, bytes, sizeof(bytes)) > 0) {}
}

static int await_socket(ds_test_proxy *proxy, int socket, short events) {
    struct pollfd items[2] = {{.fd = socket, .events = events},
                             {.fd = proxy->wake_read, .events = POLLIN}};
    for (;;) {
        int ignored;
        if (state(proxy, &ignored)) return ECANCELED;
        // The ten-second bound applies only to establishing the outbound fixture connection.
        int count = poll(items, 2, 10000);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return errno;
        if (!count) return ETIMEDOUT;
        if (items[1].revents) drain_wake(proxy);
        if (state(proxy, &ignored)) return ECANCELED;
        if (items[0].revents & events) return 0;
        if (items[0].revents & (POLLHUP | POLLERR | POLLNVAL)) return EPIPE;
    }
}

static int relay_read(int socket, struct proxy_buffer *buffer, int blackhole) {
    unsigned char discarded[16384];
    void *destination = blackhole ? (void *)discarded : (void *)(buffer->bytes + buffer->count);
    size_t capacity = blackhole ? sizeof(discarded) : DS_TEST_PROXY_CAPACITY - buffer->count;
    if (!capacity) return 0;
    ssize_t count = read(socket, destination, capacity);
    if (count > 0) { if (!blackhole) buffer->count += (size_t)count; return 0; }
    if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    return EPIPE;
}

static int relay_write(int socket, struct proxy_buffer *buffer) {
    ssize_t count = write(socket, buffer->bytes, buffer->count);
    if (count > 0) {
        buffer->count -= (size_t)count;
        if (buffer->count) memmove(buffer->bytes, buffer->bytes + count, buffer->count);
        return 0;
    }
    if (count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
    return EPIPE;
}

static void *run_proxy(void *context) {
    ds_test_proxy *proxy = context;
    int client = -1, server = -1, ignored;
    for (;;) {
        if (state(proxy, &ignored)) goto complete;
        struct pollfd items[2] = {{.fd = proxy->listener, .events = POLLIN},
                                 {.fd = proxy->wake_read, .events = POLLIN}};
        int count = poll(items, 2, -1);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) goto complete;
        if (items[1].revents) drain_wake(proxy);
        if (state(proxy, &ignored)) goto complete;
        if (items[0].revents & POLLIN) {
            client = accept(proxy->listener, NULL, NULL);
            if (client < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            break;
        }
        if (items[0].revents & (POLLHUP | POLLERR | POLLNVAL)) goto complete;
    }
    if (client < 0 || configure_socket(client)) goto complete;
    server = socket(proxy->target.ss_family, SOCK_STREAM, 0);
    if (server < 0 || configure_socket(server)) goto complete;
    if (connect(server, (struct sockaddr *)&proxy->target, proxy->target_length) < 0) {
        if (errno != EINPROGRESS || await_socket(proxy, server, POLLOUT)) goto complete;
        int error = 0;
        socklen_t length = sizeof(error);
        if (getsockopt(server, SOL_SOCKET, SO_ERROR, &error, &length) < 0 || error) goto complete;
    }
    struct proxy_buffer to_server = {{0}, 0}, to_client = {{0}, 0};
    for (;;) {
        int blackhole;
        if (state(proxy, &blackhole)) break;
        if (blackhole) to_server.count = to_client.count = 0;
        struct pollfd items[3] = {
            {.fd = client, .events = (blackhole || to_server.count < DS_TEST_PROXY_CAPACITY ? POLLIN : 0) |
                                    (!blackhole && to_client.count ? POLLOUT : 0)},
            {.fd = server, .events = (blackhole || to_client.count < DS_TEST_PROXY_CAPACITY ? POLLIN : 0) |
                                    (!blackhole && to_server.count ? POLLOUT : 0)},
            {.fd = proxy->wake_read, .events = POLLIN},
        };
        int count = poll(items, 3, -1);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) break;
        if (items[2].revents) drain_wake(proxy);
        // Reload after the wake, before writing any bytes that were queued when blackhole began.
        if (state(proxy, &blackhole)) break;
        if (blackhole) to_server.count = to_client.count = 0;
        if (items[0].revents & (POLLHUP | POLLERR | POLLNVAL) ||
            items[1].revents & (POLLHUP | POLLERR | POLLNVAL)) break;
        if (items[0].revents & POLLIN && relay_read(client, &to_server, blackhole)) break;
        if (items[1].revents & POLLIN && relay_read(server, &to_client, blackhole)) break;
        if (!blackhole && items[0].revents & POLLOUT && to_client.count && relay_write(client, &to_client)) break;
        if (!blackhole && items[1].revents & POLLOUT && to_server.count && relay_write(server, &to_server)) break;
    }
complete:
    if (client >= 0) close(client);
    if (server >= 0) close(server);
    if (proxy->listener >= 0) { close(proxy->listener); proxy->listener = -1; }
    pthread_mutex_lock(&proxy->lock);
    proxy->finished = 1;
    pthread_cond_broadcast(&proxy->completed);
    pthread_mutex_unlock(&proxy->lock);
    ds_test_proxy_release(proxy);
    return NULL;
}

int ds_test_proxy_start(const char *target_host, uint16_t target_port, ds_test_proxy **result) {
    if (!target_host || !*target_host || !target_port || !result) return EINVAL;
    *result = NULL;
    ds_test_proxy *proxy = calloc(1, sizeof(*proxy));
    if (!proxy) return ENOMEM;
    proxy->listener = proxy->wake_read = proxy->wake_write = -1;
    int error = pthread_mutex_init(&proxy->lock, NULL);
    if (error) { free(proxy); return error; }
    error = pthread_cond_init(&proxy->completed, NULL);
    if (error) { pthread_mutex_destroy(&proxy->lock); free(proxy); return error; }
    proxy->references = 1;
    char port[6];
    if (snprintf(port, sizeof(port), "%u", target_port) < 0) { error = EINVAL; goto fail; }
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *resolved = NULL;
    if (getaddrinfo(target_host, port, &hints, &resolved) != 0 || !resolved) { error = EHOSTUNREACH; goto fail; }
    if (resolved->ai_addrlen > sizeof(proxy->target)) { freeaddrinfo(resolved); error = EINVAL; goto fail; }
    memcpy(&proxy->target, resolved->ai_addr, resolved->ai_addrlen);
    proxy->target_length = (socklen_t)resolved->ai_addrlen;
    freeaddrinfo(resolved);
    int pipes[2];
    if (pipe(pipes) < 0) { error = errno; goto fail; }
    proxy->wake_read = pipes[0]; proxy->wake_write = pipes[1];
    if ((error = configure(pipes[0])) || (error = configure(pipes[1]))) goto fail;
    proxy->listener = socket(AF_INET, SOCK_STREAM, 0);
    if (proxy->listener < 0) { error = errno; goto fail; }
    if ((error = configure_socket(proxy->listener))) goto fail;
    struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
                                  .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)}, .sin_port = 0};
    if (bind(proxy->listener, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(proxy->listener, 1) < 0) {
        error = errno; goto fail;
    }
    socklen_t address_length = sizeof(address);
    if (getsockname(proxy->listener, (struct sockaddr *)&address, &address_length) < 0) { error = errno; goto fail; }
    proxy->port = ntohs(address.sin_port);
    pthread_t worker;
    ds_test_proxy_retain(proxy);
    error = pthread_create(&worker, NULL, run_proxy, proxy);
    if (error) { ds_test_proxy_release(proxy); goto fail; }
    pthread_detach(worker);
    *result = proxy;
    return 0;
fail:
    ds_test_proxy_release(proxy);
    return error;
}

uint16_t ds_test_proxy_port(ds_test_proxy *proxy) { return proxy->port; }

void ds_test_proxy_blackhole(ds_test_proxy *proxy) {
    pthread_mutex_lock(&proxy->lock);
    proxy->blackhole = 1;
    wake(proxy);
    pthread_mutex_unlock(&proxy->lock);
}

void ds_test_proxy_cancel(ds_test_proxy *proxy) {
    pthread_mutex_lock(&proxy->lock);
    proxy->canceled = 1;
    wake(proxy);
    pthread_mutex_unlock(&proxy->lock);
}

void ds_test_proxy_wait(ds_test_proxy *proxy) {
    pthread_mutex_lock(&proxy->lock);
    while (!proxy->finished) pthread_cond_wait(&proxy->completed, &proxy->lock);
    pthread_mutex_unlock(&proxy->lock);
}
