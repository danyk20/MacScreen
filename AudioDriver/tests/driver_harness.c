// Offline harness for MacScreenAudio.driver: loads the built bundle the way the Core Audio
// driver service does (Info.plist CFPlugInTypes -> factory UUID -> factory function name ->
// dlsym), then drives the AudioServerPlugInDriverInterface like coreaudiod: Initialize with a
// fake host, sweep every object x standard property x scope, and run a loopback IO cycle.
// Usage: driver_harness path/to/MacScreenAudio.driver
#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int gFailures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { gFailures++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static const char *FourCC(UInt32 v, char buf[8]) {
    buf[0] = (char)(v >> 24); buf[1] = (char)(v >> 16); buf[2] = (char)(v >> 8); buf[3] = (char)v; buf[4] = 0;
    for (int i = 0; i < 4; i++) if (buf[i] < 32 || buf[i] > 126) { snprintf(buf, 8, "%u", v); break; }
    return buf;
}

// ------------------------------------------------------------------ fake host
static int gChangedCalls = 0;
static OSStatus Host_PropertiesChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) {
    gChangedCalls++;
    CHECK(o >= 1 && o <= 6, "PropertiesChanged for unknown object %u", o);
    return 0;
}
static OSStatus Host_CopyFromStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef *out) { *out = NULL; return kAudioHardwareUnknownPropertyError; }
static OSStatus Host_WriteToStorage(AudioServerPlugInHostRef h, CFStringRef k, CFPropertyListRef d) { return 0; }
static OSStatus Host_DeleteFromStorage(AudioServerPlugInHostRef h, CFStringRef k) { return 0; }
static OSStatus Host_RequestDeviceConfigurationChange(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 a, void *i) { return 0; }
static AudioServerPlugInHostInterface gHost = {
    Host_PropertiesChanged, Host_CopyFromStorage, Host_WriteToStorage, Host_DeleteFromStorage,
    Host_RequestDeviceConfigurationChange,
};

// ------------------------------------------------------------------ property catalogue
typedef enum { T_ANY, T_U32, T_F32, T_F64, T_CLASS, T_OBJ, T_OBJLIST, T_CFSTR, T_ASBD, T_RANGED, T_VRANGE, T_CFURL } PType;
typedef struct { AudioObjectPropertySelector sel; PType type; } PropSpec;

static const PropSpec kProps[] = {
    {kAudioObjectPropertyBaseClass, T_CLASS}, {kAudioObjectPropertyClass, T_CLASS}, {kAudioObjectPropertyOwner, T_OBJ},
    {kAudioObjectPropertyName, T_CFSTR}, {kAudioObjectPropertyModelName, T_CFSTR}, {kAudioObjectPropertyManufacturer, T_CFSTR},
    {kAudioObjectPropertyElementName, T_CFSTR}, {kAudioObjectPropertyElementCategoryName, T_CFSTR},
    {kAudioObjectPropertyElementNumberName, T_CFSTR}, {kAudioObjectPropertyOwnedObjects, T_OBJLIST},
    {kAudioObjectPropertyIdentify, T_U32}, {kAudioObjectPropertySerialNumber, T_CFSTR},
    {kAudioObjectPropertyFirmwareVersion, T_CFSTR}, {kAudioObjectPropertyCustomPropertyInfoList, T_ANY},
    {kAudioObjectPropertyControlList, T_OBJLIST},
    {kAudioPlugInPropertyBundleID, T_CFSTR}, {kAudioPlugInPropertyDeviceList, T_OBJLIST},
    {kAudioPlugInPropertyTranslateUIDToDevice, T_OBJ}, {kAudioPlugInPropertyBoxList, T_OBJLIST},
    {kAudioPlugInPropertyTranslateUIDToBox, T_OBJ}, {kAudioPlugInPropertyClockDeviceList, T_OBJLIST},
    {kAudioPlugInPropertyTranslateUIDToClockDevice, T_OBJ}, {kAudioPlugInPropertyResourceBundle, T_CFSTR},
    {kAudioDevicePropertyConfigurationApplication, T_CFSTR}, {kAudioDevicePropertyDeviceUID, T_CFSTR},
    {kAudioDevicePropertyModelUID, T_CFSTR}, {kAudioDevicePropertyTransportType, T_U32},
    {kAudioDevicePropertyRelatedDevices, T_OBJLIST}, {kAudioDevicePropertyClockDomain, T_U32},
    {kAudioDevicePropertyDeviceIsAlive, T_U32}, {kAudioDevicePropertyDeviceIsRunning, T_U32},
    {kAudioDevicePropertyDeviceCanBeDefaultDevice, T_U32}, {kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, T_U32},
    {kAudioDevicePropertyLatency, T_U32}, {kAudioDevicePropertyStreams, T_OBJLIST},
    {kAudioDevicePropertySafetyOffset, T_U32}, {kAudioDevicePropertyNominalSampleRate, T_F64},
    {kAudioDevicePropertyAvailableNominalSampleRates, T_VRANGE}, {kAudioDevicePropertyIcon, T_CFURL},
    {kAudioDevicePropertyIsHidden, T_U32}, {kAudioDevicePropertyPreferredChannelsForStereo, T_ANY},
    {kAudioDevicePropertyPreferredChannelLayout, T_ANY}, {kAudioDevicePropertyZeroTimeStampPeriod, T_U32},
    {kAudioDevicePropertyClockIsStable, T_U32}, {kAudioDevicePropertyClockAlgorithm, T_U32},
    {kAudioDevicePropertyHogMode, T_ANY}, {kAudioDevicePropertyBufferFrameSize, T_U32},
    {kAudioDevicePropertyStreamConfiguration, T_ANY}, {kAudioDevicePropertyActualSampleRate, T_F64},
    {kAudioStreamPropertyIsActive, T_U32}, {kAudioStreamPropertyDirection, T_U32},
    {kAudioStreamPropertyTerminalType, T_U32}, {kAudioStreamPropertyStartingChannel, T_U32},
    {kAudioStreamPropertyLatency, T_U32}, {kAudioStreamPropertyVirtualFormat, T_ASBD},
    {kAudioStreamPropertyAvailableVirtualFormats, T_RANGED}, {kAudioStreamPropertyPhysicalFormat, T_ASBD},
    {kAudioStreamPropertyAvailablePhysicalFormats, T_RANGED},
    {kAudioControlPropertyScope, T_U32}, {kAudioControlPropertyElement, T_U32},
    {kAudioLevelControlPropertyScalarValue, T_F32}, {kAudioLevelControlPropertyDecibelValue, T_F32},
    {kAudioLevelControlPropertyDecibelRange, T_VRANGE}, {kAudioLevelControlPropertyConvertScalarToDecibels, T_F32},
    {kAudioLevelControlPropertyConvertDecibelsToScalar, T_F32}, {kAudioBooleanControlPropertyValue, T_U32},
    {kAudioSelectorControlPropertyCurrentItem, T_ANY}, {kAudioStereoPanControlPropertyValue, T_F32},
};
static const AudioObjectPropertyScope kScopes[] = {
    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput,
    kAudioObjectPropertyScopePlayThrough, kAudioObjectPropertyScopeWildcard,
};
static const AudioObjectPropertyElement kElements[] = { kAudioObjectPropertyElementMain, 1, 2, kAudioObjectPropertyElementWildcard };

static UInt32 FixedSize(PType t) {
    switch (t) {
    case T_U32: case T_F32: case T_CLASS: case T_OBJ: return 4;
    case T_F64: return 8;
    case T_CFSTR: case T_CFURL: return sizeof(void *);
    case T_ASBD: return sizeof(AudioStreamBasicDescription);
    default: return 0;
    }
}

static AudioServerPlugInDriverRef gDrv;
#define D (*gDrv)

typedef struct { AudioObjectID id; AudioClassID expectClass; AudioClassID expectBase; const char *name; } ObjSpec;
static const ObjSpec kObjects[] = {
    {1, kAudioPlugInClassID, kAudioObjectClassID, "plug-in"},
    {2, kAudioDeviceClassID, kAudioObjectClassID, "device"},
    {3, kAudioStreamClassID, kAudioObjectClassID, "output stream"},
    {4, kAudioStreamClassID, kAudioObjectClassID, "input stream"},
    {5, kAudioVolumeControlClassID, kAudioLevelControlClassID, "volume"},
    {6, kAudioMuteControlClassID, kAudioBooleanControlClassID, "mute"},
};
static Boolean IsValidObject(AudioObjectID o) { return o >= 1 && o <= 6; }

static void SweepProperties(void) {
    char c1[8], c2[8];
    CFStringRef uid = CFSTR("app.macscreen.audio.device");
    int checked = 0;
    for (size_t oi = 0; oi < sizeof kObjects / sizeof kObjects[0]; oi++) {
        AudioObjectID obj = kObjects[oi].id;
        for (size_t pi = 0; pi < sizeof kProps / sizeof kProps[0]; pi++) {
            for (size_t si = 0; si < sizeof kScopes / sizeof kScopes[0]; si++) {
                for (size_t ei = 0; ei < sizeof kElements / sizeof kElements[0]; ei++) {
                    AudioObjectPropertyAddress a = { kProps[pi].sel, kScopes[si], kElements[ei] };
                    const char *sel = FourCC(a.mSelector, c1), *scp = FourCC(a.mScope, c2);
                    const void *qual = NULL; UInt32 qualSize = 0;
                    if (a.mSelector == kAudioPlugInPropertyTranslateUIDToDevice) { qual = &uid; qualSize = sizeof uid; }
                    Boolean has = D->HasProperty(gDrv, obj, 0, &a);
                    UInt32 size = 0xDEAD;
                    OSStatus e = D->GetPropertyDataSize(gDrv, obj, 0, &a, qualSize, qual, &size);
                    Boolean settable = false;
                    OSStatus es = D->IsPropertySettable(gDrv, obj, 0, &a, &settable);
                    if (!has) {
                        CHECK(e == kAudioHardwareUnknownPropertyError, "%s '%s'/'%s': unsupported but GetPropertyDataSize returned %d (want 'who?')", kObjects[oi].name, sel, scp, (int)e);
                        CHECK(es == kAudioHardwareUnknownPropertyError, "%s '%s': unsupported but IsPropertySettable returned %d", kObjects[oi].name, sel, (int)es);
                        UInt8 buf[256]; UInt32 got = 0;
                        e = D->GetPropertyData(gDrv, obj, 0, &a, qualSize, qual, sizeof buf, &got, buf);
                        CHECK(e == kAudioHardwareUnknownPropertyError, "%s '%s': unsupported but GetPropertyData returned %d", kObjects[oi].name, sel, (int)e);
                        continue;
                    }
                    checked++;
                    CHECK(es == 0, "%s '%s': IsPropertySettable failed %d", kObjects[oi].name, sel, (int)es);
                    CHECK(e == 0, "%s '%s'/'%s': HasProperty true but GetPropertyDataSize failed %d", kObjects[oi].name, sel, scp, (int)e);
                    if (e != 0) continue;
                    UInt32 fixed = FixedSize(kProps[pi].type);
                    if (fixed) CHECK(size == fixed, "%s '%s': size %u, want %u", kObjects[oi].name, sel, size, fixed);
                    UInt8 *buf = calloc(1, size + 16);
                    if (a.mSelector == kAudioLevelControlPropertyConvertScalarToDecibels) *(Float32 *)buf = 0.5f;
                    if (a.mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar) *(Float32 *)buf = -6.0f;
                    UInt32 got = 0xDEAD;
                    e = D->GetPropertyData(gDrv, obj, 0, &a, qualSize, qual, size, &got, buf);
                    CHECK(e == 0, "%s '%s'/'%s': GetPropertyData failed %d", kObjects[oi].name, sel, scp, (int)e);
                    CHECK(got == size, "%s '%s'/'%s': GetPropertyData size %u != GetPropertyDataSize %u", kObjects[oi].name, sel, scp, got, size);
                    if (e == 0) switch (kProps[pi].type) {
                    case T_CLASS: {
                        AudioClassID v = *(AudioClassID *)buf;
                        AudioClassID want = a.mSelector == kAudioObjectPropertyClass ? kObjects[oi].expectClass : kObjects[oi].expectBase;
                        CHECK(v == want, "%s '%s': class '%s' want '%s'", kObjects[oi].name, sel, FourCC(v, c2), FourCC(want, (char[8]){0}));
                        break; }
                    case T_OBJ: {
                        AudioObjectID v = *(AudioObjectID *)buf;
                        if (a.mSelector == kAudioPlugInPropertyTranslateUIDToDevice) CHECK(v == 2, "TranslateUIDToDevice -> %u", v);
                        else CHECK(v == kAudioObjectUnknown || IsValidObject(v), "%s '%s': invalid object %u", kObjects[oi].name, sel, v);
                        break; }
                    case T_OBJLIST:
                        CHECK(size % sizeof(AudioObjectID) == 0, "%s '%s': list size %u", kObjects[oi].name, sel, size);
                        for (UInt32 i = 0; i < size / 4; i++)
                            CHECK(IsValidObject(((AudioObjectID *)buf)[i]), "%s '%s': list holds invalid object %u", kObjects[oi].name, sel, ((AudioObjectID *)buf)[i]);
                        break;
                    case T_CFSTR: {
                        CFTypeRef s = *(CFTypeRef *)buf;
                        CHECK(s != NULL && CFGetTypeID(s) == CFStringGetTypeID(), "%s '%s': not a CFString", kObjects[oi].name, sel);
                        if (s) { CHECK(CFGetRetainCount(s) >= 1, "%s '%s': CFString not retained", kObjects[oi].name, sel); CFRelease(s); }
                        break; }
                    case T_ASBD: {
                        AudioStreamBasicDescription *f = (void *)buf;
                        CHECK(f->mSampleRate == 48000 && f->mFormatID == kAudioFormatLinearPCM && f->mChannelsPerFrame == 2 &&
                              f->mBytesPerFrame == 8 && f->mBitsPerChannel == 32 && (f->mFormatFlags & kAudioFormatFlagIsFloat),
                              "%s '%s': bad ASBD", kObjects[oi].name, sel);
                        break; }
                    case T_RANGED:
                        CHECK(size > 0 && size % sizeof(AudioStreamRangedDescription) == 0, "%s '%s': ranged size %u", kObjects[oi].name, sel, size);
                        if (size) { AudioStreamRangedDescription *r = (void *)buf;
                            CHECK(r->mFormat.mSampleRate == 48000 && r->mSampleRateRange.mMinimum == 48000, "%s '%s': bad ranged format", kObjects[oi].name, sel); }
                        break;
                    case T_VRANGE:
                        CHECK(size > 0 && size % sizeof(AudioValueRange) == 0, "%s '%s': range size %u", kObjects[oi].name, sel, size);
                        break;
                    default: break;
                    }
                    // Too-small buffer for fixed-size properties must not succeed silently.
                    if (fixed && kProps[pi].type != T_CFSTR) {
                        UInt32 small = 0;
                        e = D->GetPropertyData(gDrv, obj, 0, &a, qualSize, qual, fixed - 1, &small, buf);
                        CHECK(e != 0, "%s '%s': undersized buffer accepted", kObjects[oi].name, sel);
                    }
                    free(buf);
                }
            }
        }
    }
    // Bad objects.
    AudioObjectPropertyAddress a = { kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, 0 };
    UInt32 sz;
    CHECK(!D->HasProperty(gDrv, 99, 0, &a), "object 99 has properties");
    CHECK(D->GetPropertyDataSize(gDrv, 99, 0, &a, 0, NULL, &sz) == kAudioHardwareBadObjectError, "object 99 size not '!obj'");
    // Scoped lists.
    AudioObjectPropertyAddress s = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, 0 };
    AudioObjectID ids[8]; UInt32 got = 0;
    D->GetPropertyData(gDrv, 2, 0, &s, 0, NULL, sizeof ids, &got, ids);
    CHECK(got == 4 && ids[0] == 4, "input streams list wrong");
    s.mScope = kAudioObjectPropertyScopeOutput;
    D->GetPropertyData(gDrv, 2, 0, &s, 0, NULL, sizeof ids, &got, ids);
    CHECK(got == 4 && ids[0] == 3, "output streams list wrong");
    UInt32 dir; s = (AudioObjectPropertyAddress){ kAudioStreamPropertyDirection, 0, 0 }; s.mScope = kAudioObjectPropertyScopeGlobal;
    D->GetPropertyData(gDrv, 4, 0, &s, 0, NULL, 4, &got, &dir); CHECK(dir == 1, "input stream direction %u", dir);
    D->GetPropertyData(gDrv, 3, 0, &s, 0, NULL, 4, &got, &dir); CHECK(dir == 0, "output stream direction %u", dir);
    printf("property sweep: %d supported (object, property, scope, element) combinations checked\n", checked);
}

static void SetF32(AudioObjectID o, AudioObjectPropertySelector sel, Float32 v) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, 0 };
    CHECK(D->SetPropertyData(gDrv, o, 0, &a, 0, NULL, sizeof v, &v) == 0, "set f32 failed");
}
static void SetU32(AudioObjectID o, AudioObjectPropertySelector sel, UInt32 v) {
    AudioObjectPropertyAddress a = { sel, kAudioObjectPropertyScopeGlobal, 0 };
    CHECK(D->SetPropertyData(gDrv, o, 0, &a, 0, NULL, sizeof v, &v) == 0, "set u32 failed");
}

static void IOCycle(Float64 sampleTime, UInt32 frames, float value, float *outIn) {
    AudioServerPlugInIOCycleInfo info = {0};
    info.mIOCycleCounter = 1;
    info.mNominalIOBufferFrameSize = frames;
    info.mOutputTime.mSampleTime = sampleTime;
    info.mInputTime.mSampleTime = sampleTime;
    info.mOutputTime.mFlags = info.mInputTime.mFlags = kAudioTimeStampSampleTimeValid;
    float *buf = calloc(frames * 2, sizeof(float));
    for (UInt32 i = 0; i < frames * 2; i++) buf[i] = value;
    Boolean will, inPlace;
    CHECK(D->WillDoIOOperation(gDrv, 2, 7, kAudioServerPlugInIOOperationWriteMix, &will, &inPlace) == 0 && will, "WriteMix not done");
    CHECK(D->BeginIOOperation(gDrv, 2, 7, kAudioServerPlugInIOOperationWriteMix, frames, &info) == 0, "BeginIO");
    CHECK(D->DoIOOperation(gDrv, 2, 3, 7, kAudioServerPlugInIOOperationWriteMix, frames, &info, buf, NULL) == 0, "DoIO write");
    CHECK(D->EndIOOperation(gDrv, 2, 7, kAudioServerPlugInIOOperationWriteMix, frames, &info) == 0, "EndIO");
    memset(buf, 0xFF, frames * 2 * sizeof(float));
    CHECK(D->WillDoIOOperation(gDrv, 2, 7, kAudioServerPlugInIOOperationReadInput, &will, &inPlace) == 0 && will, "ReadInput not done");
    CHECK(D->DoIOOperation(gDrv, 2, 4, 7, kAudioServerPlugInIOOperationReadInput, frames, &info, buf, NULL) == 0, "DoIO read");
    memcpy(outIn, buf, frames * 2 * sizeof(float));
    free(buf);
}

static void ExerciseIO(void) {
    CHECK(D->StartIO(gDrv, 2, 7) == 0, "StartIO");
    Float64 st; UInt64 ht, seed;
    CHECK(D->GetZeroTimeStamp(gDrv, 2, 7, &st, &ht, &seed) == 0 && st == 0 && ht > 0, "GetZeroTimeStamp");
    AudioObjectPropertyAddress run = { kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, 0 };
    UInt32 r = 0, got; D->GetPropertyData(gDrv, 2, 0, &run, 0, NULL, 4, &got, &r); CHECK(r == 1, "not running after StartIO");
    Boolean will, inPlace;
    D->WillDoIOOperation(gDrv, 2, 7, kAudioServerPlugInIOOperationMixOutput, &will, &inPlace); CHECK(!will, "MixOutput should not be done");

    enum { N = 512 };
    float in[N * 2];
    SetF32(5, kAudioLevelControlPropertyScalarValue, 1.0f); SetU32(6, kAudioBooleanControlPropertyValue, 0);
    IOCycle(0, N, 0.25f, in);
    CHECK(fabsf(in[0] - 0.25f) < 1e-6f && fabsf(in[N * 2 - 1] - 0.25f) < 1e-6f, "loopback unity: got %f", in[0]);
    SetF32(5, kAudioLevelControlPropertyScalarValue, 0.5f);
    IOCycle(N, N, 0.25f, in);
    CHECK(fabsf(in[0] - 0.125f) < 1e-6f, "loopback volume 0.5: got %f", in[0]);
    SetF32(5, kAudioLevelControlPropertyDecibelValue, -96.0f);
    IOCycle(2 * N, N, 0.25f, in);
    CHECK(in[0] == 0.0f, "loopback volume -96 dB: got %f", in[0]);
    SetF32(5, kAudioLevelControlPropertyScalarValue, 1.0f); SetU32(6, kAudioBooleanControlPropertyValue, 1);
    IOCycle(3 * N, N, 0.25f, in);
    CHECK(in[0] == 0.0f, "loopback mute: got %f", in[0]);
    SetU32(6, kAudioBooleanControlPropertyValue, 0);
    IOCycle(4 * N, N, 0.75f, in);
    CHECK(fabsf(in[0] - 0.75f) < 1e-6f, "loopback unmuted: got %f", in[0]);

    CHECK(D->StopIO(gDrv, 2, 7) == 0, "StopIO");
    r = 1; D->GetPropertyData(gDrv, 2, 0, &run, 0, NULL, 4, &got, &r); CHECK(r == 0, "running after StopIO");
    CHECK(D->StartIO(gDrv, 99, 7) == kAudioHardwareBadObjectError, "StartIO on bad object");
    printf("IO loopback: unity, volume, dB, mute checked; PropertiesChanged calls: %d\n", gChangedCalls);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s MacScreenAudio.driver\n", argv[0]); return 2; }
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)argv[1], (CFIndex)strlen(argv[1]), true);
    CFBundleRef bundle = CFBundleCreate(NULL, url);
    if (!bundle) { fprintf(stderr, "FAIL: cannot open bundle %s\n", argv[1]); return 1; }
    CFDictionaryRef info = CFBundleGetInfoDictionary(bundle);
    CFDictionaryRef types = CFDictionaryGetValue(info, CFSTR("CFPlugInTypes"));
    CFDictionaryRef factories = CFDictionaryGetValue(info, CFSTR("CFPlugInFactories"));
    CFStringRef typeKey = CFUUIDCreateString(NULL, kAudioServerPlugInTypeUUID);
    CFArrayRef factoryIDs = types ? CFDictionaryGetValue(types, typeKey) : NULL;
    if (!factoryIDs || CFArrayGetCount(factoryIDs) < 1 || !factories) { fprintf(stderr, "FAIL: Info.plist has no factory for the AudioServerPlugIn type\n"); return 1; }
    CFStringRef fname = CFDictionaryGetValue(factories, CFArrayGetValueAtIndex(factoryIDs, 0));
    char name[128] = {0};
    if (!fname || !CFStringGetCString(fname, name, sizeof name, kCFStringEncodingUTF8)) { fprintf(stderr, "FAIL: factory UUID not in CFPlugInFactories\n"); return 1; }
    char exe[1024];
    CFURLRef exeURL = CFBundleCopyExecutableURL(bundle);
    CFURLGetFileSystemRepresentation(exeURL, true, (UInt8 *)exe, sizeof exe);
    void *h = dlopen(exe, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FAIL: dlopen: %s\n", dlerror()); return 1; }
    typedef void *(*Factory)(CFAllocatorRef, CFUUIDRef);
    Factory factory = (Factory)dlsym(h, name);   // what CFPlugIn does in the driver service
    if (!factory) { fprintf(stderr, "FAIL: dlsym(%s): %s (symbol not exported)\n", name, dlerror()); return 1; }
    printf("factory %s found via dlsym\n", name);

    CHECK(factory(NULL, kAudioServerPlugInDriverInterfaceUUID) == NULL, "factory accepted a wrong type UUID");
    void *unk = factory(NULL, kAudioServerPlugInTypeUUID);
    if (!unk) { fprintf(stderr, "FAIL: factory returned NULL for kAudioServerPlugInTypeUUID\n"); return 1; }
    IUnknownVTbl **iu = unk;
    void *drvPtr = NULL;
    CHECK((*iu)->QueryInterface(unk, CFUUIDGetUUIDBytes(kAudioServerPlugInDriverInterfaceUUID), &drvPtr) == S_OK && drvPtr, "QueryInterface(driver)");
    gDrv = drvPtr;
    D->Release(gDrv);
    AudioServerPlugInHostRef host = &gHost;
    CHECK(D->Initialize(gDrv, host) == 0, "Initialize");

    SweepProperties();
    ExerciseIO();

    if (gFailures) { fprintf(stderr, "driver harness: %d failure(s)\n", gFailures); return 1; }
    printf("driver harness: all checks passed\n");
    return 0;
}
