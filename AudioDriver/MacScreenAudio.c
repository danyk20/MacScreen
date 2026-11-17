// MacScreen virtual audio device (AudioServerPlugIn).
// One device "MacScreen Display": 48 kHz, 2 ch, Float32. Whatever is played to the output
// stream is looped back to the input stream through a ring buffer (MSLoopbackRing.h), with
// the output volume and mute controls applied on the way in. The MacScreen Host captures the
// input side and sends it to the Display.
// Structure follows the documented AudioServerPlugIn model (plug-in, device, streams,
// controls); the code is original.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "MSLoopbackRing.h"

#define kDeviceUID        "app.macscreen.audio.device"
#define kDeviceModelUID   "app.macscreen.audio.model"
#define kDeviceName       "MacScreen Display"
#define kManufacturerName "MacScreen"
#define kSampleRate       48000.0
#define kChannels         2
#define kBitsPerChannel   32
#define kBytesPerFrame    (kChannels * sizeof(Float32))
#define kRingFrames       16384
#define kZeroTimeStampPeriod 16384
#define kMinDb            (-96.0f)

enum {
    kObjectPlugIn       = kAudioObjectPlugInObject, // 1
    kObjectDevice       = 2,
    kObjectOutputStream = 3,
    kObjectInputStream  = 4,
    kObjectVolume       = 5,
    kObjectMute         = 6,
};

// ---------------------------------------------------------------- state

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 1;
static UInt64 gIOCount = 0;
static UInt64 gTimeStampCount = 0;
static UInt64 gAnchorHostTime = 0;
static Float64 gHostTicksPerPeriod = 0;
static _Atomic float gVolume = 1.0f;
static _Atomic int gMute = 0;
static _Atomic int gOutputActive = 1;
static _Atomic int gInputActive = 1;
static float gRingStore[kRingFrames * kChannels];
static MSLoopbackRing gRing;

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = kBitsPerChannel;
    return f;
}

static float ScalarToDb(float s) { return s <= 0 ? kMinDb : fmaxf(kMinDb, 20.0f * log10f(s)); }
static float DbToScalar(float db) { return db <= kMinDb ? 0 : fminf(1.0f, powf(10.0f, db / 20.0f)); }

// ---------------------------------------------------------------- property helpers

static Boolean IsAllScope(AudioObjectPropertyScope s) {
    return s == kAudioObjectPropertyScopeGlobal || s == kAudioObjectPropertyScopeWildcard;
}

// Copies `size` bytes of `value` into the output, or reports an error.
static OSStatus PutBytes(const void *value, UInt32 size, UInt32 inSize, UInt32 *outSize, void *outData) {
    *outSize = size;
    if (outData == NULL) return kAudioHardwareNoError;           // size query
    if (inSize < size) return kAudioHardwareBadPropertySizeError;
    memcpy(outData, value, size);
    return kAudioHardwareNoError;
}
#define PUT(type, v) do { type _v = (v); return PutBytes(&_v, sizeof(type), inSize, outSize, outData); } while (0)

// Lists may be truncated to whatever fits.
static OSStatus PutList(const AudioObjectID *ids, UInt32 count, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (outData == NULL) { *outSize = count * sizeof(AudioObjectID); return kAudioHardwareNoError; }
    UInt32 fit = inSize / sizeof(AudioObjectID);
    if (fit > count) fit = count;
    memcpy(outData, ids, fit * sizeof(AudioObjectID));
    *outSize = fit * sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

static CFStringRef MakeString(const char *s) { return CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8); }
#define PUT_CFSTRING(cstr) do { CFStringRef _s = MakeString(cstr); \
    OSStatus _e = PutBytes(&_s, sizeof(CFStringRef), inSize, outSize, outData); \
    if (outData == NULL || _e != kAudioHardwareNoError) CFRelease(_s); return _e; } while (0)

static UInt32 OwnedByDevice(AudioObjectPropertyScope scope, AudioObjectID *list, Boolean controlsOnly, Boolean streamsOnly) {
    UInt32 n = 0;
    if (!controlsOnly) {
        if (IsAllScope(scope) || scope == kAudioObjectPropertyScopeOutput) list[n++] = kObjectOutputStream;
        if (IsAllScope(scope) || scope == kAudioObjectPropertyScopeInput) list[n++] = kObjectInputStream;
    }
    if (!streamsOnly) {
        if (IsAllScope(scope) || scope == kAudioObjectPropertyScopeOutput) {
            list[n++] = kObjectVolume;
            list[n++] = kObjectMute;
        }
    }
    return n;
}

static Boolean ObjectExists(AudioObjectID o) { return o >= kObjectPlugIn && o <= kObjectMute; }

// ---------------------------------------------------------------- property tables

static Boolean HasProp(AudioObjectID obj, const AudioObjectPropertyAddress *a) {
    switch (obj) {
    case kObjectPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle: return true;
        } return false;
    case kObjectDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive: case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertyStreams: case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod: return true;
        } return false;
    case kObjectOutputStream: case kObjectInputStream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: return true;
        } return false;
    case kObjectVolume:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioControlPropertyScope: case kAudioControlPropertyElement:
        case kAudioLevelControlPropertyScalarValue: case kAudioLevelControlPropertyDecibelValue:
        case kAudioLevelControlPropertyDecibelRange: case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar: return true;
        } return false;
    case kObjectMute:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioControlPropertyScope: case kAudioControlPropertyElement:
        case kAudioBooleanControlPropertyValue: return true;
        } return false;
    }
    return false;
}

static Boolean IsSettable(AudioObjectID obj, const AudioObjectPropertyAddress *a) {
    switch (obj) {
    case kObjectDevice: return a->mSelector == kAudioDevicePropertyNominalSampleRate;
    case kObjectOutputStream: case kObjectInputStream:
        return a->mSelector == kAudioStreamPropertyIsActive || a->mSelector == kAudioStreamPropertyVirtualFormat ||
               a->mSelector == kAudioStreamPropertyPhysicalFormat;
    case kObjectVolume: return a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue;
    case kObjectMute: return a->mSelector == kAudioBooleanControlPropertyValue;
    }
    return false;
}

static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qualSize, const void *qual,
                        UInt32 inSize, UInt32 *outSize, void *outData) {
    AudioObjectID list[8];
    switch (obj) {
    case kObjectPlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT_CFSTRING(kManufacturerName);
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
            list[0] = kObjectDevice; return PutList(list, 1, inSize, outSize, outData);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (outData == NULL) { *outSize = sizeof(AudioObjectID); return kAudioHardwareNoError; }
            if (qualSize != sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = MakeString(kDeviceUID);
            Boolean match = CFEqual(*(CFStringRef *)qual, uid);
            CFRelease(uid);
            PUT(AudioObjectID, match ? kObjectDevice : kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle: PUT_CFSTRING("");
        }
        break;
    case kObjectDevice:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectPlugIn);
        case kAudioObjectPropertyName: PUT_CFSTRING(kDeviceName);
        case kAudioObjectPropertyManufacturer: PUT_CFSTRING(kManufacturerName);
        case kAudioObjectPropertyOwnedObjects: {
            UInt32 n = OwnedByDevice(a->mScope, list, false, false); return PutList(list, n, inSize, outSize, outData);
        }
        case kAudioDevicePropertyDeviceUID: PUT_CFSTRING(kDeviceUID);
        case kAudioDevicePropertyModelUID: PUT_CFSTRING(kDeviceModelUID);
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: list[0] = kObjectDevice; return PutList(list, 1, inSize, outSize, outData);
        case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex); UInt32 r = gIOCount > 0; pthread_mutex_unlock(&gStateMutex);
            PUT(UInt32, r);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, 1);
        case kAudioDevicePropertyLatency: PUT(UInt32, 0);
        case kAudioDevicePropertyStreams: {
            UInt32 n = OwnedByDevice(a->mScope, list, false, true); return PutList(list, n, inSize, outSize, outData);
        }
        case kAudioObjectPropertyControlList: {
            UInt32 n = OwnedByDevice(a->mScope, list, true, false); return PutList(list, n, inSize, outSize, outData);
        }
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            return PutBytes(&r, sizeof r, inSize, outSize, outData);
        }
        case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kZeroTimeStampPeriod);
        }
        break;
    case kObjectOutputStream: case kObjectInputStream: {
        Boolean isOut = obj == kObjectOutputStream;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectDevice);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive: PUT(UInt32, isOut ? atomic_load(&gOutputActive) : atomic_load(&gInputActive));
        case kAudioStreamPropertyDirection: PUT(UInt32, isOut ? 0 : 1);
        case kAudioStreamPropertyTerminalType: PUT(UInt32, isOut ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency: PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat: {
            AudioStreamBasicDescription f = StreamFormat();
            return PutBytes(&f, sizeof f, inSize, outSize, outData);
        }
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r = { StreamFormat(), { kSampleRate, kSampleRate } };
            return PutBytes(&r, sizeof r, inSize, outSize, outData);
        }
        }
        break;
    }
    case kObjectVolume: case kObjectMute: {
        Boolean isVol = obj == kObjectVolume;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, isVol ? kAudioLevelControlClassID : kAudioBooleanControlClassID);
        case kAudioObjectPropertyClass: PUT(AudioClassID, isVol ? kAudioVolumeControlClassID : kAudioMuteControlClassID);
        case kAudioObjectPropertyOwner: PUT(AudioObjectID, kObjectDevice);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
        case kAudioControlPropertyScope: PUT(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: PUT(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        case kAudioBooleanControlPropertyValue:
            if (!isVol) PUT(UInt32, atomic_load(&gMute) ? 1 : 0);
            break;
        case kAudioLevelControlPropertyScalarValue:
            if (isVol) PUT(Float32, atomic_load(&gVolume));
            break;
        case kAudioLevelControlPropertyDecibelValue:
            if (isVol) PUT(Float32, ScalarToDb(atomic_load(&gVolume)));
            break;
        case kAudioLevelControlPropertyDecibelRange:
            if (isVol) { AudioValueRange r = { kMinDb, 0.0 }; return PutBytes(&r, sizeof r, inSize, outSize, outData); }
            break;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
            if (isVol) {
                if (inSize < sizeof(Float32) && outData) return kAudioHardwareBadPropertySizeError;
                if (outData == NULL) { *outSize = sizeof(Float32); return kAudioHardwareNoError; }
                float v = *(Float32 *)outData; v = fminf(1.0f, fmaxf(0.0f, v));
                *(Float32 *)outData = ScalarToDb(v); *outSize = sizeof(Float32); return kAudioHardwareNoError;
            }
            break;
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if (isVol) {
                if (inSize < sizeof(Float32) && outData) return kAudioHardwareBadPropertySizeError;
                if (outData == NULL) { *outSize = sizeof(Float32); return kAudioHardwareNoError; }
                *(Float32 *)outData = DbToScalar(*(Float32 *)outData); *outSize = sizeof(Float32); return kAudioHardwareNoError;
            }
            break;
        }
        break;
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static void NotifyChanged(AudioObjectID obj, AudioObjectPropertySelector sel) {
    if (gHost == NULL) return;
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    gHost->PropertiesChanged(gHost, obj, 1, &a);
}

static OSStatus SetProp(AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 inSize, const void *data) {
    switch (obj) {
    case kObjectDevice:
        if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
            if (inSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
            return *(const Float64 *)data == kSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
        }
        break;
    case kObjectOutputStream: case kObjectInputStream:
        if (a->mSelector == kAudioStreamPropertyIsActive) {
            if (inSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            atomic_store(obj == kObjectOutputStream ? &gOutputActive : &gInputActive, *(const UInt32 *)data != 0);
            NotifyChanged(obj, kAudioStreamPropertyIsActive);
            return kAudioHardwareNoError;
        }
        if (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) {
            if (inSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
            const AudioStreamBasicDescription *f = data, want = StreamFormat();
            if (f->mSampleRate != want.mSampleRate || f->mFormatID != want.mFormatID || f->mFormatFlags != want.mFormatFlags ||
                f->mChannelsPerFrame != want.mChannelsPerFrame || f->mBitsPerChannel != want.mBitsPerChannel)
                return kAudioDeviceUnsupportedFormatError;
            return kAudioHardwareNoError;
        }
        break;
    case kObjectVolume:
        if (a->mSelector == kAudioLevelControlPropertyScalarValue || a->mSelector == kAudioLevelControlPropertyDecibelValue) {
            if (inSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
            float v = *(const Float32 *)data;
            if (a->mSelector == kAudioLevelControlPropertyDecibelValue) v = DbToScalar(v);
            atomic_store(&gVolume, fminf(1.0f, fmaxf(0.0f, v)));
            NotifyChanged(obj, kAudioLevelControlPropertyScalarValue);
            NotifyChanged(obj, kAudioLevelControlPropertyDecibelValue);
            return kAudioHardwareNoError;
        }
        break;
    case kObjectMute:
        if (a->mSelector == kAudioBooleanControlPropertyValue) {
            if (inSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            atomic_store(&gMute, *(const UInt32 *)data != 0);
            NotifyChanged(obj, kAudioBooleanControlPropertyValue);
            return kAudioHardwareNoError;
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------- driver interface

static HRESULT Drv_QueryInterface(void *self, REFIID uuid, LPVOID *out);
static ULONG Drv_AddRef(void *self);
static ULONG Drv_Release(void *self);

static OSStatus Drv_Initialize(AudioServerPlugInDriverRef d, AudioServerPlugInHostRef host) {
    gHost = host;
    ms_ring_init(&gRing, gRingStore, kRingFrames, kChannels);
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    Float64 ticksPerSec = ((Float64)tb.denom / (Float64)tb.numer) * 1.0e9;
    gHostTicksPerPeriod = ticksPerSec * ((Float64)kZeroTimeStampPeriod / kSampleRate);
    return kAudioHardwareNoError;
}
static OSStatus Drv_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo *c, AudioObjectID *out) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus Drv_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus Drv_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return kAudioHardwareNoError; }
static OSStatus Drv_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return kAudioHardwareNoError; }
static OSStatus Drv_PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 action, void *info) { return kAudioHardwareNoError; }
static OSStatus Drv_AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID o, UInt64 action, void *info) { return kAudioHardwareNoError; }

static Boolean Drv_HasProperty(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a) {
    if (a == NULL || !ObjectExists(o)) return false;
    return HasProp(o, a);
}
static OSStatus Drv_IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a, Boolean *out) {
    if (a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!ObjectExists(o)) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    *out = IsSettable(o, a);
    return kAudioHardwareNoError;
}
static OSStatus Drv_GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a,
                                        UInt32 qs, const void *q, UInt32 *out) {
    if (a == NULL || out == NULL) return kAudioHardwareIllegalOperationError;
    if (!ObjectExists(o)) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    return GetProp(o, a, qs, q, 0, out, NULL);
}
static OSStatus Drv_GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qs, const void *q, UInt32 inSize, UInt32 *outSize, void *outData) {
    if (a == NULL || outSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!ObjectExists(o)) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    // The host may pass a NULL buffer for a property whose size is 0 (empty owned-object lists).
    UInt64 scratch = 0;
    if (outData == NULL) { inSize = 0; outData = &scratch; }
    return GetProp(o, a, qs, q, inSize, outSize, outData);
}
static OSStatus Drv_SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID o, pid_t pid, const AudioObjectPropertyAddress *a,
                                    UInt32 qs, const void *q, UInt32 inSize, const void *data) {
    if (a == NULL || data == NULL) return kAudioHardwareIllegalOperationError;
    if (!ObjectExists(o)) return kAudioHardwareBadObjectError;
    if (!HasProp(o, a)) return kAudioHardwareUnknownPropertyError;
    return SetProp(o, a, inSize, data);
}

static OSStatus Drv_StartIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 clientID) {
    if (o != kObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount == UINT64_MAX) { pthread_mutex_unlock(&gStateMutex); return kAudioHardwareIllegalOperationError; }
    if (gIOCount == 0) {
        gTimeStampCount = 0;
        gAnchorHostTime = mach_absolute_time();
        ms_ring_reset(&gRing);
    }
    gIOCount++;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}
static OSStatus Drv_StopIO(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 clientID) {
    if (o != kObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    if (gIOCount > 0) gIOCount--;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}
static OSStatus Drv_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 clientID,
                                     Float64 *outSample, UInt64 *outHost, UInt64 *outSeed) {
    if (o != kObjectDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt64 now = mach_absolute_time();
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * gHostTicksPerPeriod);
    if (next <= now) gTimeStampCount++;
    *outSample = (Float64)gTimeStampCount * (Float64)kZeroTimeStampPeriod;
    *outHost = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * gHostTicksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&gStateMutex);
    return kAudioHardwareNoError;
}
static OSStatus Drv_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 clientID, UInt32 op,
                                      Boolean *willDo, Boolean *inPlace) {
    if (o != kObjectDevice) return kAudioHardwareBadObjectError;
    *willDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return kAudioHardwareNoError;
}
static OSStatus Drv_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 clientID, UInt32 op, UInt32 frames,
                                     const AudioServerPlugInIOCycleInfo *info) { return kAudioHardwareNoError; }
static OSStatus Drv_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, AudioObjectID streamID, UInt32 clientID, UInt32 op,
                                  UInt32 frames, const AudioServerPlugInIOCycleInfo *info, void *main, void *secondary) {
    if (o != kObjectDevice) return kAudioHardwareBadObjectError;
    if (op == kAudioServerPlugInIOOperationReadInput && streamID == kObjectInputStream) {
        if (atomic_load(&gInputActive)) ms_ring_read(&gRing, (int64_t)info->mInputTime.mSampleTime, frames, (float *)main);
        else memset(main, 0, (size_t)frames * kBytesPerFrame);
    } else if (op == kAudioServerPlugInIOOperationWriteMix && streamID == kObjectOutputStream) {
        if (atomic_load(&gOutputActive)) {
            float gain = atomic_load(&gMute) ? 0.0f : atomic_load(&gVolume);
            ms_ring_write(&gRing, (int64_t)info->mOutputTime.mSampleTime, frames, (const float *)main, gain);
        }
    }
    return kAudioHardwareNoError;
}
static OSStatus Drv_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID o, UInt32 clientID, UInt32 op, UInt32 frames,
                                   const AudioServerPlugInIOCycleInfo *info) { return kAudioHardwareNoError; }

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    Drv_QueryInterface, Drv_AddRef, Drv_Release,
    Drv_Initialize, Drv_CreateDevice, Drv_DestroyDevice, Drv_AddDeviceClient, Drv_RemoveDeviceClient,
    Drv_PerformConfigChange, Drv_AbortConfigChange,
    Drv_HasProperty, Drv_IsPropertySettable, Drv_GetPropertyDataSize, Drv_GetPropertyData, Drv_SetPropertyData,
    Drv_StartIO, Drv_StopIO, Drv_GetZeroTimeStamp,
    Drv_WillDoIOOperation, Drv_BeginIOOperation, Drv_DoIOOperation, Drv_EndIOOperation,
};
static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef gDriverRef = &gDriverInterfacePtr;

static HRESULT Drv_QueryInterface(void *self, REFIID uuid, LPVOID *out) {
    if (out == NULL) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex); gRefCount++; pthread_mutex_unlock(&gStateMutex);
        *out = gDriverRef;
        result = S_OK;
    } else {
        *out = NULL;
    }
    CFRelease(requested);
    return result;
}
static ULONG Drv_AddRef(void *self) {
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) gRefCount++;
    ULONG r = gRefCount; pthread_mutex_unlock(&gStateMutex); return r;
}
static ULONG Drv_Release(void *self) {
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount; pthread_mutex_unlock(&gStateMutex); return r;
}

// Factory named in Info.plist (CFPlugInFactories). Must have default visibility: the driver is
// built with -fvisibility=hidden, and a hidden symbol cannot be exported by -exported_symbol, so
// CFPlugIn's dlsym would fail ("Cannot find function pointer MacScreenAudio_Create").
__attribute__((visibility("default"))) void *MacScreenAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}
