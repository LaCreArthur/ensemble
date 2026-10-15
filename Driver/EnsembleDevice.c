// Ensemble's sound device (an Audio Server plug-in, loaded by coreaudiod). While Ensemble shares this
// Mac's sound, apps play to this device, and a hidden twin on the same clock, read only by Ensemble,
// gives each sample back at the sample time it was played (a loopback): apps never see an input on the
// device they play to. The device reports Ensemble's delay as its latency, so video players hold the
// picture back by the same amount (as they do for AirPlay). Its volume and mute are values Ensemble
// mirrors and applies itself.
//
// The device exists only while Ensemble asks for it: Ensemble sets the plug-in's custom property
// kAttach to the latency in frames (>= 0), or to -1 to remove the device. The device also goes when the
// process that set it exits, so a crash never leaves the Mac playing to a device that plays nothing.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>

#define SAMPLE_RATE 48000.0
#define CHANNELS 2
#define ZERO_TIME_STAMP_PERIOD 16384
#define DEVICE_NAME "Ensemble"
#define DEVICE_UID "com.lacrearthur.ensemble.device"
#define CAPTURE_UID "com.lacrearthur.ensemble.capture"
#define MANUFACTURER "Ensemble"
#define MIN_DB -64.0f
/// The loopback holds one zero-time-stamp period: far more than an IO cycle's span from write to read.
#define RING_FRAMES ZERO_TIME_STAMP_PERIOD

enum { kPlugIn = kAudioObjectPlugInObject, kDevice = 2, kStream = 3, kVolume = 4, kMute = 5, kCapture = 6, kCaptureStream = 7 };
/// Both devices run on one clock, so an aggregate needs no drift correction between them.
enum { kClockDomain = 'ensm' };
/// CFNumber: the latency in frames while the device exists, -1 while it does not.
enum { kAttach = 'enld' };

static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface *gInterfacePointer = &gInterface;
static AudioServerPlugInDriverRef gDriver = &gInterfacePointer;
static AudioServerPlugInHostRef gHost;
/// Runs host notifications, configuration change requests and the watch on the attaching process.
static dispatch_queue_t gQueue;
static os_log_t gLog;

static _Atomic UInt32 gRefCount = 0;
static _Atomic Boolean gAttached = false;
static _Atomic UInt32 gLatency = 0;
static _Atomic Float32 gVolume = 1;
static _Atomic UInt32 gMuted = 0;
// The clock.
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt64 gIOCount = 0;
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStamps = 0;
// The loopback: the output's IO thread writes each frame, then its sample time + 1; the capture's IO
// thread reads a frame only while that stamp matches the sample time it asks for, so it never gives a
// frame twice, a frame from an earlier lap, or one not written yet (silence instead).
static Float32 gRing[RING_FRAMES * CHANNELS];
static _Atomic UInt64 gStamp[RING_FRAMES];
// Only touched on gQueue.
static pid_t gClient = 0;
static dispatch_source_t gWatch;

// MARK: Properties

typedef struct {
    UInt32 size;
    union {
        UInt32 u32;
        Float32 f32;
        Float64 f64;
        CFStringRef string;
        AudioObjectID ids[4];
        AudioValueRange range;
        AudioStreamBasicDescription format;
        AudioStreamRangedDescription rangedFormat;
        AudioServerPlugInCustomPropertyInfo custom;
        UInt32 channels[2];
        struct { AudioChannelLayout layout; AudioChannelDescription second; } layout;
    } v;
} Value;

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = SAMPLE_RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * CHANNELS;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * CHANNELS;
    f.mChannelsPerFrame = CHANNELS;
    f.mBitsPerChannel = 32;
    return f;
}

static Float32 Clamp(Float32 x) { return x < 0 ? 0 : x > 1 ? 1 : x; }
static Float32 ScalarToDecibels(Float32 scalar) { return MIN_DB * (1 - Clamp(scalar)); }
static Float32 DecibelsToScalar(Float32 db) { return Clamp(1 - db / MIN_DB); }

#define U32(x) do { out->size = sizeof(UInt32); out->v.u32 = (x); return true; } while (0)
#define F32(x) do { out->size = sizeof(Float32); out->v.f32 = (x); return true; } while (0)
#define STRING(x) do { out->size = sizeof(CFStringRef); out->v.string = CFSTR(x); return true; } while (0)
#define IDS(...) do { AudioObjectID list[] = {__VA_ARGS__}; out->size = sizeof list; memcpy(out->v.ids, list, sizeof list); return true; } while (0)
#define NONE() do { out->size = 0; return true; } while (0)

// Fills `out` with the value of a property; false if the object does not have it. Values computed
// from the caller's data (the attach number, dB conversions) only get their size here.
static Boolean Lookup(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 qualifierSize, const void *qualifier, Value *out) {
    Boolean input = a->mScope == kAudioObjectPropertyScopeInput;
    Boolean output = a->mScope == kAudioObjectPropertyScopeOutput;
    Boolean capture = object == kCapture || object == kCaptureStream;
    switch (object) {
    case kPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: U32(kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: U32(kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: STRING(MANUFACTURER);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            if (gAttached) IDS(kDevice, kCapture);
            NONE();
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CFStringRef uid = gAttached && qualifierSize == sizeof(CFStringRef) && qualifier ? *(const CFStringRef *)qualifier : NULL;
            if (uid && CFStringCompare(uid, CFSTR(DEVICE_UID), 0) == kCFCompareEqualTo) U32(kDevice);
            if (uid && CFStringCompare(uid, CFSTR(CAPTURE_UID), 0) == kCFCompareEqualTo) U32(kCapture);
            U32(kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle: STRING("");
        case kAudioObjectPropertyCustomPropertyInfoList:
            out->size = sizeof(AudioServerPlugInCustomPropertyInfo);
            out->v.custom = (AudioServerPlugInCustomPropertyInfo){kAttach, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                                                                  kAudioServerPlugInCustomPropertyDataTypeNone};
            return true;
        case kAttach:
            out->size = sizeof(CFPropertyListRef);
            return true;
        }
        return false;
    case kDevice:
    case kCapture:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: U32(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: U32(kPlugIn);
        case kAudioObjectPropertyName:
            if (capture) STRING(DEVICE_NAME " capture");
            STRING(DEVICE_NAME);
        case kAudioObjectPropertyManufacturer: STRING(MANUFACTURER);
        case kAudioObjectPropertyOwnedObjects:
            if (capture) { if (output) NONE(); IDS(kCaptureStream); }
            if (input) NONE();
            IDS(kStream, kVolume, kMute);
        case kAudioDevicePropertyStreams:
            if (capture) { if (output) NONE(); IDS(kCaptureStream); }
            if (input) NONE();
            IDS(kStream);
        case kAudioObjectPropertyControlList:
            if (capture) NONE();
            IDS(kVolume, kMute);
        case kAudioObjectPropertyCustomPropertyInfoList: NONE();
        case kAudioDevicePropertyDeviceUID:
            if (capture) STRING(CAPTURE_UID);
            STRING(DEVICE_UID);
        case kAudioDevicePropertyModelUID: STRING(DEVICE_UID ".model");
        case kAudioDevicePropertyTransportType: U32(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: IDS(kDevice, kCapture);
        case kAudioDevicePropertyClockDomain: U32(kClockDomain);
        case kAudioDevicePropertyDeviceIsAlive: U32(1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gMutex);
            UInt32 running = gIOCount > 0;
            pthread_mutex_unlock(&gMutex);
            U32(running);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: U32(!capture && !input);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: U32(0);
        case kAudioDevicePropertyLatency: U32(capture || input ? 0 : gLatency);
        case kAudioDevicePropertySafetyOffset: U32(0);
        case kAudioDevicePropertyIsHidden: U32(capture);
        case kAudioDevicePropertyZeroTimeStampPeriod: U32(ZERO_TIME_STAMP_PERIOD);
        case kAudioDevicePropertyNominalSampleRate:
            out->size = sizeof(Float64);
            out->v.f64 = SAMPLE_RATE;
            return true;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            out->size = sizeof(AudioValueRange);
            out->v.range = (AudioValueRange){SAMPLE_RATE, SAMPLE_RATE};
            return true;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            out->size = 2 * sizeof(UInt32);
            out->v.channels[0] = 1;
            out->v.channels[1] = 2;
            return true;
        case kAudioDevicePropertyPreferredChannelLayout:
            out->size = offsetof(AudioChannelLayout, mChannelDescriptions) + CHANNELS * sizeof(AudioChannelDescription);
            memset(&out->v.layout, 0, sizeof(out->v.layout));
            out->v.layout.layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            out->v.layout.layout.mNumberChannelDescriptions = CHANNELS;
            out->v.layout.layout.mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            out->v.layout.second.mChannelLabel = kAudioChannelLabel_Right;
            return true;
        }
        return false;
    case kStream:
    case kCaptureStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: U32(kAudioStreamClassID);
        case kAudioObjectPropertyOwner: U32(capture ? kCapture : kDevice);
        case kAudioObjectPropertyOwnedObjects: NONE();
        case kAudioStreamPropertyIsActive: U32(1);
        case kAudioStreamPropertyDirection: U32(capture);
        case kAudioStreamPropertyTerminalType: U32(capture ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: U32(1);
        case kAudioStreamPropertyLatency: U32(0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            out->size = sizeof(AudioStreamBasicDescription);
            out->v.format = Format();
            return true;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            out->size = sizeof(AudioStreamRangedDescription);
            out->v.rangedFormat.mFormat = Format();
            out->v.rangedFormat.mSampleRateRange = (AudioValueRange){SAMPLE_RATE, SAMPLE_RATE};
            return true;
        }
        return false;
    case kVolume:
    case kMute:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: U32(object == kVolume ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass: U32(object == kVolume ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner: U32(kDevice);
        case kAudioObjectPropertyOwnedObjects: NONE();
        case kAudioControlPropertyScope: U32(kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: U32(kAudioObjectPropertyElementMain);
        }
        if (object == kMute) {
            if (a->mSelector == kAudioBooleanControlPropertyValue) U32(gMuted);
            return false;
        }
        switch (a->mSelector) {
        case kAudioLevelControlPropertyScalarValue: F32(gVolume);
        case kAudioLevelControlPropertyDecibelValue: F32(ScalarToDecibels(gVolume));
        case kAudioLevelControlPropertyDecibelRange:
            out->size = sizeof(AudioValueRange);
            out->v.range = (AudioValueRange){MIN_DB, 0};
            return true;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: F32(0);
        }
        return false;
    }
    return false;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a) {
    Value v;
    return Lookup(object, a, 0, NULL, &v);
}

static Boolean Settable(AudioObjectID object, AudioObjectPropertySelector selector) {
    return (object == kPlugIn && selector == kAttach)
        || (object == kVolume && (selector == kAudioLevelControlPropertyScalarValue || selector == kAudioLevelControlPropertyDecibelValue))
        || (object == kMute && selector == kAudioBooleanControlPropertyValue);
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *settable) {
    if (!HasProperty(d, object, pid, a)) return kAudioHardwareUnknownPropertyError;
    *settable = Settable(object, a->mSelector);
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qualifierSize, const void *qualifier, UInt32 *size) {
    Value v;
    if (!Lookup(object, a, qualifierSize, qualifier, &v)) return kAudioHardwareUnknownPropertyError;
    *size = v.size;
    return noErr;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qualifierSize, const void *qualifier, UInt32 inSize, UInt32 *outSize, void *data) {
    Value v;
    if (!Lookup(object, a, qualifierSize, qualifier, &v)) return kAudioHardwareUnknownPropertyError;
    Boolean computed = (object == kPlugIn && a->mSelector == kAttach) || (object == kVolume && v.size == sizeof(Float32));
    if (computed && inSize < v.size) return kAudioHardwareBadPropertySizeError;
    if (object == kPlugIn && a->mSelector == kAttach) {
        SInt64 value = gAttached ? (SInt64)gLatency : -1;
        *(CFPropertyListRef *)data = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);   // the host releases it
    } else if (object == kVolume && a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels) {
        *(Float32 *)data = ScalarToDecibels(*(Float32 *)data);
    } else if (object == kVolume && a->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
        *(Float32 *)data = DecibelsToScalar(*(Float32 *)data);
    } else {
        v.size = v.size < inSize ? v.size : inSize;   // a list may be read in part
        memcpy(data, &v.v, v.size);
    }
    *outSize = v.size;
    return noErr;
}

// MARK: Presence

static void Changed(AudioObjectID object, AudioObjectPropertySelector first, AudioObjectPropertySelector second) {
    dispatch_async(gQueue, ^{
        AudioObjectPropertyAddress changes[2] = {
            {first, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {second, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        };
        if (gHost) gHost->PropertiesChanged(gHost, object, second ? 2 : 1, changes);
    });
}

static void DeviceListChanged(void) { Changed(kPlugIn, kAudioObjectPropertyOwnedObjects, kAudioPlugInPropertyDeviceList); }

// On gQueue: the device follows `client`'s life; 0 stops watching.
static void Watch(pid_t client) {
    if (client == gClient) return;
    if (gWatch) dispatch_source_cancel(gWatch);
    gWatch = NULL;
    gClient = client;
    if (!client) return;
    gWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)client, DISPATCH_PROC_EXIT, gQueue);
    if (!gWatch) return os_log_error(gLog, "cannot watch process %d: the device stays after it exits", client);
    dispatch_source_set_event_handler(gWatch, ^{
        if (gClient != client) return;
        os_log(gLog, "process %d exited: removing the device", client);
        gAttached = false;
        Watch(0);
        DeviceListChanged();
    });
    dispatch_resume(gWatch);
}

static void Attach(pid_t client, SInt64 frames) {
    Boolean attach = frames >= 0;
    UInt32 latency = attach ? (UInt32)frames : 0;
    Boolean was = atomic_exchange(&gAttached, attach);
    Boolean latencyChanged = was && attach && latency != gLatency;
    if (attach && !was) gLatency = latency;
    os_log(gLog, "process %d: %{public}s, latency %u frames", client, attach ? "attach" : "detach", latency);
    dispatch_async(gQueue, ^{
        Watch(attach ? client : 0);
        if (latencyChanged && gHost) gHost->RequestDeviceConfigurationChange(gHost, kDevice, latency, NULL);
    });
    if (attach != was) DeviceListChanged();
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *a,
                                UInt32 qualifierSize, const void *qualifier, UInt32 size, const void *data) {
    if (!HasProperty(d, object, pid, a)) return kAudioHardwareUnknownPropertyError;
    if (!Settable(object, a->mSelector)) return kAudioHardwareUnsupportedOperationError;
    if (object == kPlugIn) {
        CFNumberRef number = size == sizeof(CFPropertyListRef) ? *(const CFNumberRef *)data : NULL;
        SInt64 frames;
        if (!number || CFGetTypeID(number) != CFNumberGetTypeID() || !CFNumberGetValue(number, kCFNumberSInt64Type, &frames))
            return kAudioHardwareIllegalOperationError;
        Attach(pid, frames);
    } else if (object == kMute) {
        if (size < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        gMuted = *(const UInt32 *)data != 0;
        Changed(kMute, kAudioBooleanControlPropertyValue, 0);
    } else {
        if (size < sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
        Float32 value = *(const Float32 *)data;
        gVolume = a->mSelector == kAudioLevelControlPropertyScalarValue ? Clamp(value) : DecibelsToScalar(value);
        Changed(kVolume, kAudioLevelControlPropertyScalarValue, kAudioLevelControlPropertyDecibelValue);
    }
    return noErr;
}

// MARK: Lifetime

static HRESULT QueryInterface(void *d, REFIID uuid, LPVOID *out) {
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        gRefCount++;
        *out = gDriver;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *d) { return ++gRefCount; }
static ULONG Release(void *d) { return gRefCount > 0 ? --gRefCount : 0; }

static OSStatus Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    gHost = host;
    gQueue = dispatch_queue_create("com.lacrearthur.ensemble.device", DISPATCH_QUEUE_SERIAL);
    gLog = os_log_create("com.lacrearthur.ensemble", "device");
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    gHostTicksPerFrame = 1e9 * timebase.denom / timebase.numer / SAMPLE_RATE;
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef description, const AudioServerPlugInClientInfo *client, AudioObjectID *device) {
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID device) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *client) { return noErr; }
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID device, const AudioServerPlugInClientInfo *client) { return noErr; }

// The only configuration change is a new latency, carried in the action.
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) {
    gLatency = (UInt32)action;
    return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID device, UInt64 action, void *info) { return noErr; }

// MARK: IO (a clock on the host clock, and the loopback)

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&gMutex);
    if (gIOCount++ == 0) {   // both devices share the clock: it starts with the first one
        gTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
    }
    pthread_mutex_unlock(&gMutex);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client) {
    pthread_mutex_lock(&gMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gMutex);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, Float64 *sampleTime, UInt64 *hostTime, UInt64 *seed) {
    pthread_mutex_lock(&gMutex);
    Float64 ticksPerPeriod = gHostTicksPerFrame * ZERO_TIME_STAMP_PERIOD;
    if (gAnchorHostTime + (UInt64)((gTimeStamps + 1) * ticksPerPeriod) <= mach_absolute_time()) gTimeStamps++;
    *sampleTime = (Float64)(gTimeStamps * ZERO_TIME_STAMP_PERIOD);
    *hostTime = gAnchorHostTime + (UInt64)(gTimeStamps * ticksPerPeriod);
    *seed = 1;
    pthread_mutex_unlock(&gMutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation, Boolean *willDo, Boolean *inPlace) {
    *willDo = operation == (device == kCapture ? kAudioServerPlugInIOOperationReadInput : kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) { return noErr; }
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, AudioObjectID stream, UInt32 client, UInt32 operation, UInt32 frames,
                              const AudioServerPlugInIOCycleInfo *cycle, void *main, void *secondary) {
    Boolean write = operation == kAudioServerPlugInIOOperationWriteMix;
    if (!write && operation != kAudioServerPlugInIOOperationReadInput) return noErr;
    UInt64 start = (UInt64)(write ? cycle->mOutputTime : cycle->mInputTime).mSampleTime;
    Float32 *sound = main;
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 time = start + i;
        UInt32 at = (UInt32)(time % RING_FRAMES);
        Float32 *frame = gRing + at * CHANNELS, *own = sound + i * CHANNELS;
        if (write) {
            atomic_store_explicit(&gStamp[at], 0, memory_order_relaxed);
            atomic_thread_fence(memory_order_release);
            memcpy(frame, own, CHANNELS * sizeof(Float32));
            atomic_store_explicit(&gStamp[at], time + 1, memory_order_release);
        } else {
            Boolean ok = atomic_load_explicit(&gStamp[at], memory_order_acquire) == time + 1;
            if (ok) memcpy(own, frame, CHANNELS * sizeof(Float32));
            atomic_thread_fence(memory_order_acquire);
            if (!ok || atomic_load_explicit(&gStamp[at], memory_order_relaxed) != time + 1) memset(own, 0, CHANNELS * sizeof(Float32));
        }
    }
    return noErr;
}
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID device, UInt32 client, UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) { return noErr; }

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable, GetPropertyDataSize,
    GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};

// Factory named in Info.plist.
void *EnsembleDevice_Create(CFAllocatorRef allocator, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gDriver : NULL;
}
