#import "ObjCExceptionCatcher.h"

BOOL ObjCTryBlock(void(^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"ObjCException"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Unknown ObjC exception"}];
        }
        return NO;
    }
}
