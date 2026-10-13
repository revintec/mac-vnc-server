#include "CVNCSession.h"
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDShared.h>
#include <Carbon/Carbon.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

struct VNCConsoleInput {
    VNCConsoleIdentity identity;
    io_connect_t connection;
};

static int32_t bounded32(double value) {
    if (!isfinite(value)) return 0;
    return (int32_t)fmax(INT32_MIN, fmin(INT32_MAX, round(value)));
}

static int16_t bounded16(int64_t value) {
    return (int16_t)(value < INT16_MIN ? INT16_MIN : value > INT16_MAX ? INT16_MAX : value);
}

static UniChar physicalCharacter(uint16_t code, uint32_t flags, uint32_t keyboardType) {
    // CGEventSetFlags can leave a physical key event without a Unicode string.
    // Resolve that key through the session's layout instead of sending a NUL
    // character for shifted letters and punctuation. Explicit Unicode supplied
    // by the viewer is preserved separately below.
    TISInputSourceRef source = TISCopyCurrentKeyboardLayoutInputSource();
    if (!source) return 0;
    CFDataRef data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    UniChar chars[4] = {0}; UniCharCount length = 0; UInt32 dead = 0;
    if (data && CFGetTypeID(data) == CFDataGetTypeID()) {
        UCKeyTranslate((const UCKeyboardLayout *)CFDataGetBytePtr(data), code, kUCKeyActionDown,
            (flags >> 16) & 0xff, keyboardType ? keyboardType : LMGetKbdType(),
            kUCKeyTranslateNoDeadKeysMask, &dead, 4, &length, chars);
    }
    CFRelease(source);
    return length == 1 ? chars[0] : 0;
}

int VNCConsoleEncodeInput(CGEventRef event, VNCConsoleInputEvent *output) {
    if (!event || !output) return EINVAL;
    memset(output, 0, sizeof(*output));
    output->type = CGEventGetType(event);
    output->flags = (uint32_t)CGEventGetFlags(event);
    switch (output->type) {
        case NX_MOUSEMOVED: case NX_LMOUSEDRAGGED: case NX_RMOUSEDRAGGED: case NX_OMOUSEDRAGGED:
            output->data.mouseMove.dx = bounded32(CGEventGetIntegerValueField(event, kCGMouseEventDeltaX));
            output->data.mouseMove.dy = bounded32(CGEventGetIntegerValueField(event, kCGMouseEventDeltaY));
            break;
        case NX_LMOUSEDOWN: case NX_LMOUSEUP: case NX_RMOUSEDOWN: case NX_RMOUSEUP:
        case NX_OMOUSEDOWN: case NX_OMOUSEUP:
            output->data.mouse.buttonNumber = (uint8_t)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            output->data.mouse.click = bounded32(CGEventGetIntegerValueField(event, kCGMouseEventClickState));
            output->data.mouse.eventNum = bounded16(CGEventGetIntegerValueField(event, kCGMouseEventNumber));
            output->data.mouse.pressure = (uint8_t)fmax(0, fmin(255,
                CGEventGetDoubleValueField(event, kCGMouseEventPressure) * 255));
            break;
        case NX_KEYDOWN: case NX_KEYUP: case NX_FLAGSCHANGED: {
            int64_t code = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
            if (code < 0 || code > UINT16_MAX) return EINVAL;
            output->data.key.keyCode = (uint16_t)code;
            output->data.key.keyboardType = (uint32_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeyboardType);
            output->data.key.repeat = CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat) != 0;
            if (output->type != NX_FLAGSCHANGED) {
                UniChar chars[2] = {0}; UniCharCount length = 0;
                CGEventKeyboardGetUnicodeString(event, 2, &length, chars);
                // NX keyboard records contain one UTF-16 unit. Do not silently
                // turn a multi-unit Unicode event into a different character.
                if (length > 1) return ENOTSUP;
                output->data.key.charCode = length ? chars[0] :
                    physicalCharacter((uint16_t)code, output->flags, output->data.key.keyboardType);
                CGEventRef original = CGEventCreateCopy(event);
                if (!original) return ENOMEM;
                CGEventSetFlags(original, 0);
                CGEventKeyboardGetUnicodeString(original, 2, &length, chars);
                CFRelease(original);
                output->data.key.origCharCode = length ? chars[0] :
                    physicalCharacter((uint16_t)code, 0, output->data.key.keyboardType);
            }
            return 0; // Key events must not move the physical pointer.
        }
        case NX_SCROLLWHEELMOVED:
            output->data.scrollWheel.deltaAxis1 = bounded16(CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1));
            output->data.scrollWheel.deltaAxis2 = bounded16(CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2));
            output->data.scrollWheel.deltaAxis3 = bounded16(CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis3));
            output->data.scrollWheel.fixedDeltaAxis1 = bounded32(CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1) * 65536);
            output->data.scrollWheel.fixedDeltaAxis2 = bounded32(CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2) * 65536);
            output->data.scrollWheel.fixedDeltaAxis3 = bounded32(CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis3) * 65536);
            output->data.scrollWheel.pointDeltaAxis1 = bounded32(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1));
            output->data.scrollWheel.pointDeltaAxis2 = bounded32(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2));
            output->data.scrollWheel.pointDeltaAxis3 = bounded32(CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis3));
            return 0;
        default: return ENOTSUP;
    }
    CGPoint point = CGEventGetLocation(event);
    if (!isfinite(point.x) || !isfinite(point.y) || point.x < INT32_MIN || point.x > INT32_MAX ||
        point.y < INT32_MIN || point.y > INT32_MAX) return EINVAL;
    output->location = (IOGPoint){bounded32(point.x), bounded32(point.y)};
    output->options = kIOHIDSetCursorPosition;
    // Never set global modifier flags: flags belong to this event, and must
    // not remain latched across worker replacement or a physical user switch.
    return 0;
}

VNCConsoleInputRef VNCConsoleInputCreate(VNCConsoleIdentity identity, int32_t *error) {
    int32_t result = identity.uid == 0 ? VNCConsoleVerify(identity) : EPERM;
    if (!result && IOHIDCheckAccess(kIOHIDRequestTypePostEvent) != kIOHIDAccessTypeGranted) result = EACCES;
    if (result) { if (error) *error = result; return NULL; }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"));
    if (!service) { if (error) *error = ENODEV; return NULL; }
    VNCConsoleInputRef input = calloc(1, sizeof(*input));
    if (!input) { IOObjectRelease(service); if (error) *error = ENOMEM; return NULL; }
    input->identity = identity;
    result = IOServiceOpen(service, mach_task_self(), kIOHIDParamConnectType, &input->connection);
    IOObjectRelease(service);
    if (result) { free(input); if (error) *error = result; return NULL; }
    if (error) *error = 0;
    return input;
}

int32_t VNCConsoleInputPost(VNCConsoleInputRef input, CGEventRef event) {
    if (!input) return EINVAL;
    VNCConsoleInputEvent encoded;
    int32_t result = VNCConsoleEncodeInput(event, &encoded);
    if (result) return result;
    // HID follows the physical console, unlike CG's per-session event tap.
    // Also guard releases during teardown; an old root worker must not inject
    // into a newly logged-in user's session.
    result = VNCConsoleVerify(input->identity);
    if (result) return result;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Deprecated but exported on macOS 13–26. CGEventPost at either tap was
    // accepted without delivery at loginwindow on the tested Tahoe host.
    return IOHIDPostEvent(input->connection, encoded.type, encoded.location, &encoded.data,
                          kNXEventDataVersion, encoded.flags, encoded.options);
#pragma clang diagnostic pop
}

void VNCConsoleInputDestroy(VNCConsoleInputRef input) {
    if (!input) return;
    IOServiceClose(input->connection);
    free(input);
}
