#include "CVNCSession.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int VNCSessionSendDescriptor(int transport, int descriptor) {
    char marker = 'F';
    struct iovec vector = { &marker, 1 };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } control = {0};
    struct msghdr message = {0};
    message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET; header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(header), &descriptor, sizeof(int));
    ssize_t count;
    do { count = sendmsg(transport, &message, 0); } while (count < 0 && errno == EINTR);
    return count == 1 ? 0 : (count < 0 ? errno : EIO);
}

int VNCSessionReceiveDescriptor(int transport, int *descriptor) {
    *descriptor = -1;
    char marker = 0;
    struct iovec vector = { &marker, 1 };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(16 * sizeof(int))]; } control = {0};
    struct msghdr message = {0};
    message.msg_iov = &vector; message.msg_iovlen = 1;
    message.msg_control = control.bytes; message.msg_controllen = sizeof(control.bytes);
    ssize_t count;
    do { count = recvmsg(transport, &message, 0); } while (count < 0 && errno == EINTR);
    if (count <= 0) return count < 0 ? errno : ECONNRESET;
    int descriptors[16], found = 0, invalid = 0;
    for (struct cmsghdr *h = CMSG_FIRSTHDR(&message); h; h = CMSG_NXTHDR(&message, h)) {
        if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS || h->cmsg_len < CMSG_LEN(0)) {
            invalid = 1; continue;
        }
        size_t length = h->cmsg_len - CMSG_LEN(0);
        if (length % sizeof(int)) invalid = 1;
        for (size_t i = 0; i < length / sizeof(int); i++) {
            int fd; memcpy(&fd, CMSG_DATA(h) + i * sizeof(int), sizeof(fd));
            if (found < 16) descriptors[found++] = fd; else { close(fd); invalid = 1; }
        }
    }
    if (marker != 'F' || found != 1 || invalid || (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC))) {
        for (int i = 0; i < found; i++) close(descriptors[i]);
        return EPROTO;
    }
    if (fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) < 0) {
        int error = errno; close(descriptors[0]); return error;
    }
    *descriptor = descriptors[0];
    return 0;
}
