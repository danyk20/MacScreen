#import <objc/runtime.h>
#import "CPrivateAPI.h"

static BOOL MSClassResponds(Class cls, NSArray<NSString *> *selectors) {
    if (cls == Nil) { return NO; }
    for (NSString *name in selectors) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(name)]) { return NO; }
    }
    return YES;
}

BOOL MSPrivateAPIAvailable(void) {
    return MSClassResponds(NSClassFromString(@"CGVirtualDisplayMode"),
                           @[@"initWithWidth:height:refreshRate:"])
        && MSClassResponds(NSClassFromString(@"CGVirtualDisplaySettings"),
                           @[@"setModes:", @"setHiDPI:"])
        && MSClassResponds(NSClassFromString(@"CGVirtualDisplayDescriptor"),
                           @[@"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
                             @"setVendorID:", @"setProductID:", @"setSerialNum:",
                             @"setSizeInMillimeters:", @"setRedPrimary:", @"setGreenPrimary:",
                             @"setBluePrimary:", @"setWhitePoint:", @"setQueue:",
                             @"setTerminationHandler:"])
        && MSClassResponds(NSClassFromString(@"CGVirtualDisplay"),
                           @[@"initWithDescriptor:", @"applySettings:", @"displayID"]);
}
