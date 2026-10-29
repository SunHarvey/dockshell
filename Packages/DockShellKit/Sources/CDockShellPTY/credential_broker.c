#include "DockShellCredentialBroker.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <Security/Security.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

struct ds_credential_broker {
    pthread_mutex_t lock;
    unsigned references;
    int listener;
    int wake_read;
    int wake_write;
    int canceled;
    int delivered;
    int ready;
    pid_t ssh_pid;
    uint64_t ssh_start_seconds;
    uint64_t ssh_start_microseconds;
    char directory[PATH_MAX];
    char socket_path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    char helper_path[PROC_PIDPATHINFO_MAXSIZE];
    SecRequirementRef helper_requirement;
    char token[36];
    unsigned char secret[1023];
    size_t secret_size;
};

static void erase_memory(void *memory, size_t size) {
    volatile unsigned char *position = memory;
    while (size--) *position++ = 0;
}

static int64_t monotonic_ms(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (int64_t)value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static int configure_fd(int fd) {
    return fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
           fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0 ? errno : 0;
}

static void wake(ds_credential_broker *broker) {
    unsigned char value = 1;
    ssize_t ignored = write(broker->wake_write, &value, 1);
    (void)ignored;
}

static int is_canceled(ds_credential_broker *broker) {
    pthread_mutex_lock(&broker->lock);
    int value = broker->canceled;
    pthread_mutex_unlock(&broker->lock);
    return value;
}

static void dispose(ds_credential_broker *broker) {
    if (broker->listener >= 0) close(broker->listener);
    if (broker->wake_read >= 0) close(broker->wake_read);
    if (broker->wake_write >= 0) close(broker->wake_write);
    if (broker->socket_path[0]) unlink(broker->socket_path);
    if (broker->directory[0]) rmdir(broker->directory);
    erase_memory(broker->secret, sizeof(broker->secret));
    erase_memory(broker->token, sizeof(broker->token));
    if (broker->helper_requirement) CFRelease(broker->helper_requirement);
    pthread_mutex_destroy(&broker->lock);
    free(broker);
}

int ds_credential_create(const char *temporary_root, const char *helper_path,
                         const char *token, const void *secret, size_t secret_size,
                         ds_credential_broker **result) {
    if (!result || !temporary_root || !helper_path || !token || strlen(token) != 36 ||
        secret_size > 1023 || (!secret && secret_size != 0) ||
        (secret && secret_size == 0)) return EINVAL;
    *result = NULL;
    for (size_t i = 0; i < secret_size; ++i) {
        unsigned char byte = ((const unsigned char *)secret)[i];
        if (byte == 0 || byte == '\r' || byte == '\n') return EINVAL;
    }
    ds_credential_broker *broker = calloc(1, sizeof(*broker));
    if (!broker) return ENOMEM;
    broker->listener = broker->wake_read = broker->wake_write = -1;
    int error = pthread_mutex_init(&broker->lock, NULL);
    if (error) { free(broker); return error; }
    broker->references = 1;
    if (!realpath(helper_path, broker->helper_path)) { error = errno; goto fail; }
    struct stat helper;
    if (stat(broker->helper_path, &helper) < 0) { error = errno; goto fail; }
    if (!S_ISREG(helper.st_mode) || !(helper.st_mode & S_IXUSR)) { error = EINVAL; goto fail; }
    CFURLRef helper_url = CFURLCreateFromFileSystemRepresentation(NULL,
        (const UInt8 *)broker->helper_path, (CFIndex)strlen(broker->helper_path), false);
    if (!helper_url) { error = ENOMEM; goto fail; }
    SecStaticCodeRef helper_code = NULL;
    OSStatus signature = SecStaticCodeCreateWithPath(helper_url, kSecCSDefaultFlags, &helper_code);
    CFRelease(helper_url);
    if (signature == errSecSuccess) {
        signature = SecStaticCodeCheckValidity(helper_code,
            kSecCSStrictValidate | kSecCSCheckAllArchitectures, NULL);
        if (signature == errSecSuccess)
            signature = SecCodeCopyDesignatedRequirement(helper_code, kSecCSDefaultFlags,
                                                         &broker->helper_requirement);
        CFRelease(helper_code);
    }
    if (signature != errSecSuccess || !broker->helper_requirement) { error = EPERM; goto fail; }
    int length = snprintf(broker->directory, sizeof(broker->directory),
                          "%s/ds-ap.XXXXXXXX", temporary_root);
    if (length < 0 || (size_t)length >= sizeof(broker->directory)) {
        broker->directory[0] = 0; error = ENAMETOOLONG; goto fail;
    }
    if (!mkdtemp(broker->directory)) { broker->directory[0] = 0; error = errno; goto fail; }
    if (chmod(broker->directory, 0700) < 0) { error = errno; goto fail; }
    length = snprintf(broker->socket_path, sizeof(broker->socket_path), "%s/s", broker->directory);
    if (length < 0 || (size_t)length >= sizeof(broker->socket_path)) {
        broker->socket_path[0] = 0; error = ENAMETOOLONG; goto fail;
    }
    int pipes[2];
    if (pipe(pipes) < 0) { error = errno; goto fail; }
    broker->wake_read = pipes[0]; broker->wake_write = pipes[1];
    if ((error = configure_fd(pipes[0])) || (error = configure_fd(pipes[1]))) goto fail;
    broker->listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (broker->listener < 0) { error = errno; goto fail; }
    if ((error = configure_fd(broker->listener))) goto fail;
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    strlcpy(address.sun_path, broker->socket_path, sizeof(address.sun_path));
    address.sun_len = SUN_LEN(&address);
    if (bind(broker->listener, (struct sockaddr *)&address, address.sun_len) < 0 ||
        chmod(broker->socket_path, 0600) < 0 || listen(broker->listener, 4) < 0) {
        error = errno; goto fail;
    }
    // NULL/zero is a READY-only rendezvous. It must never produce even an empty
    // askpass reply; an unexpected credential request fails closed below.
    if (secret_size) memcpy(broker->secret, secret, secret_size);
    broker->secret_size = secret_size;
    memcpy(broker->token, token, 36);
    *result = broker;
    return 0;
fail:
    dispose(broker);
    return error;
}

const char *ds_credential_socket_path(ds_credential_broker *broker) { return broker->socket_path; }

void ds_credential_retain(ds_credential_broker *broker) {
    pthread_mutex_lock(&broker->lock);
    ++broker->references;
    pthread_mutex_unlock(&broker->lock);
}

void ds_credential_release(ds_credential_broker *broker) {
    pthread_mutex_lock(&broker->lock);
    int last = --broker->references == 0;
    pthread_mutex_unlock(&broker->lock);
    if (last) dispose(broker);
}

int ds_credential_bind_ssh(ds_credential_broker *broker, pid_t ssh_pid) {
    if (ssh_pid <= 0) return EINVAL;
    struct proc_bsdinfo info;
    if (proc_pidinfo(ssh_pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return ESRCH;
    pthread_mutex_lock(&broker->lock);
    int error = broker->canceled ? ECANCELED : broker->ssh_pid != 0 ? EALREADY : 0;
    if (!error) {
        broker->ssh_pid = ssh_pid;
        broker->ssh_start_seconds = info.pbi_start_tvsec;
        broker->ssh_start_microseconds = info.pbi_start_tvusec;
    }
    pthread_mutex_unlock(&broker->lock);
    wake(broker);
    return error;
}

void ds_credential_cancel(ds_credential_broker *broker) {
    pthread_mutex_lock(&broker->lock);
    broker->canceled = 1;
    erase_memory(broker->secret, sizeof(broker->secret));
    broker->secret_size = 0;
    pthread_mutex_unlock(&broker->lock);
    wake(broker);
}

static int await_fd(ds_credential_broker *broker, int fd, short events, int64_t deadline) {
    for (;;) {
        if (is_canceled(broker)) return ECANCELED;
        int64_t remaining = deadline - monotonic_ms();
        if (remaining <= 0) return ETIMEDOUT;
        struct pollfd items[2] = {{.fd = fd, .events = events},
                                 {.fd = broker->wake_read, .events = POLLIN}};
        int count = poll(items, 2, remaining > INT_MAX ? INT_MAX : (int)remaining);
        if (count < 0) { if (errno == EINTR) continue; return errno; }
        if (count == 0) return ETIMEDOUT;
        if (items[1].revents) {
            unsigned char buffer[64];
            while (read(broker->wake_read, buffer, sizeof(buffer)) > 0) {}
            if (is_canceled(broker)) return ECANCELED;
            // Before PID binding the wake descriptor itself is the awaited event.
            // Do not wait again after consuming its notification.
            if (fd == broker->wake_read) return 0;
        }
        if (items[0].revents & events) return 0;
        if (items[0].revents & (POLLHUP | POLLERR | POLLNVAL)) return EPIPE;
    }
}

static int read_exact(ds_credential_broker *broker, int fd, void *bytes, size_t count, int64_t deadline) {
    unsigned char *position = bytes;
    while (count) {
        int error = await_fd(broker, fd, POLLIN, deadline);
        if (error) return error;
        ssize_t consumed = read(fd, position, count);
        if (consumed < 0) { if (errno == EINTR || errno == EAGAIN) continue; return errno; }
        if (consumed == 0) return EPIPE;
        position += consumed; count -= (size_t)consumed;
    }
    return 0;
}

static int write_exact(ds_credential_broker *broker, int fd, const void *bytes, size_t count, int64_t deadline) {
    const unsigned char *position = bytes;
    while (count) {
        int error = await_fd(broker, fd, POLLOUT, deadline);
        if (error) return error;
        ssize_t sent = write(fd, position, count);
        if (sent < 0) { if (errno == EINTR || errno == EAGAIN) continue; return errno; }
        if (sent == 0) return EPIPE;
        position += sent; count -= (size_t)sent;
    }
    return 0;
}

static int trusted_peer(ds_credential_broker *broker, int peer) {
    uid_t uid; gid_t gid; pid_t pid; socklen_t length = sizeof(pid);
    if (getpeereid(peer, &uid, &gid) < 0 || uid != getuid() ||
        getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) < 0 || length != sizeof(pid)) return 0;
    pthread_mutex_lock(&broker->lock);
    pid_t ssh_pid = broker->ssh_pid;
    uint64_t seconds = broker->ssh_start_seconds;
    uint64_t microseconds = broker->ssh_start_microseconds;
    pthread_mutex_unlock(&broker->lock);
    struct proc_bsdinfo parent, child;
    char path[PROC_PIDPATHINFO_MAXSIZE];
    if (ssh_pid <= 0 || proc_pidinfo(ssh_pid, PROC_PIDTBSDINFO, 0, &parent, sizeof(parent)) != sizeof(parent) ||
        parent.pbi_start_tvsec != seconds || parent.pbi_start_tvusec != microseconds ||
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &child, sizeof(child)) != sizeof(child) ||
        child.pbi_ppid != (uint32_t)ssh_pid || child.pbi_uid != getuid() ||
        proc_pidpath(pid, path, sizeof(path)) <= 0 || strcmp(path, broker->helper_path) != 0) return 0;
    // Validate the live process against the originally signed helper's requirement.
    // This dynamic check remains valid if the file at its path has been replaced.
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberIntType, &pid);
    if (!number) return 0;
    const void *keys[] = { kSecGuestAttributePid };
    const void *values[] = { number };
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(number);
    if (!attributes) return 0;
    SecCodeRef code = NULL;
    OSStatus signature = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    CFRelease(attributes);
    if (signature == errSecSuccess) {
        signature = SecCodeCheckValidity(code, kSecCSDefaultFlags, broker->helper_requirement);
        CFRelease(code);
    }
    return signature == errSecSuccess;
}

static int equal_token(const unsigned char *request, const char *token) {
    unsigned char difference = 0;
    for (size_t i = 0; i < 36; ++i) difference |= request[i] ^ (unsigned char)token[i];
    return difference == 0;
}

int ds_credential_serve(ds_credential_broker *broker) {
    int64_t deadline = monotonic_ms() + 45000;
    for (;;) {
        int error = await_fd(broker, broker->listener, POLLIN, deadline);
        if (error) return error;
        int peer = accept(broker->listener, NULL, NULL);
        if (peer < 0) { if (errno == EAGAIN || errno == EINTR) continue; return errno; }
        int no_signal = 1;
        if (configure_fd(peer) || setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &no_signal, sizeof(no_signal)) < 0) {
            close(peer); continue;
        }
        // A helper may arrive between posix_spawn and binding the returned PID.
        for (;;) {
            pthread_mutex_lock(&broker->lock);
            int bound = broker->ssh_pid != 0;
            pthread_mutex_unlock(&broker->lock);
            if (bound || is_canceled(broker)) break;
            error = await_fd(broker, broker->wake_read, POLLIN, deadline);
            if (error) break;
        }
        if (error || !trusted_peer(broker, peer)) { close(peer); if (error) return error; continue; }
        unsigned char request[37];
        int64_t request_deadline = monotonic_ms() + 3000;
        if (request_deadline > deadline) request_deadline = deadline;
        error = read_exact(broker, peer, request, sizeof(request), request_deadline);
        if (error || !equal_token(request + 1, broker->token)) { close(peer); continue; }
        if (request[0] == 'P') {
            unsigned char response[sizeof(uint32_t) + 1023];
            size_t count = 0;
            pthread_mutex_lock(&broker->lock);
            if (!broker->canceled && !broker->delivered && !broker->ready && broker->secret_size > 0) {
                uint32_t length = htonl((uint32_t)broker->secret_size);
                memcpy(response, &length, sizeof(length));
                memcpy(response + sizeof(length), broker->secret, broker->secret_size);
                count = sizeof(length) + broker->secret_size;
                // Even a disconnected authorized helper consumes this one attempt.
                broker->delivered = 1;
                erase_memory(broker->secret, sizeof(broker->secret));
                broker->secret_size = 0;
            }
            pthread_mutex_unlock(&broker->lock);
            if (count) (void)write_exact(broker, peer, response, count, request_deadline);
            erase_memory(response, sizeof(response));
            close(peer);
        } else if (request[0] == 'R') {
            uint32_t empty = 0;
            error = write_exact(broker, peer, &empty, sizeof(empty), request_deadline);
            close(peer);
            if (error) continue;
            pthread_mutex_lock(&broker->lock);
            if (!broker->canceled) broker->ready = 1;
            int ready = broker->ready;
            erase_memory(broker->secret, sizeof(broker->secret));
            broker->secret_size = 0;
            pthread_mutex_unlock(&broker->lock);
            return ready ? 0 : ECANCELED;
        } else close(peer);
    }
}

int ds_credential_was_delivered(ds_credential_broker *broker) {
    pthread_mutex_lock(&broker->lock); int value = broker->delivered; pthread_mutex_unlock(&broker->lock);
    return value;
}

void ds_credential_retire(ds_credential_broker *broker) {
    if (broker->listener >= 0) { close(broker->listener); broker->listener = -1; }
    if (broker->socket_path[0]) { unlink(broker->socket_path); broker->socket_path[0] = 0; }
    if (broker->directory[0]) { rmdir(broker->directory); broker->directory[0] = 0; }
    pthread_mutex_lock(&broker->lock);
    erase_memory(broker->secret, sizeof(broker->secret));
    broker->secret_size = 0;
    pthread_mutex_unlock(&broker->lock);
}

int ds_credential_is_ready(ds_credential_broker *broker) {
    pthread_mutex_lock(&broker->lock); int value = broker->ready; pthread_mutex_unlock(&broker->lock);
    return value;
}
