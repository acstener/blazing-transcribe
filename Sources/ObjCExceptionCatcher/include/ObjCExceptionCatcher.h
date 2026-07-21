#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Returns YES if block executed without exception. On exception, returns NO and sets error.
BOOL ObjCTryBlock(void(^block)(void), NSError *_Nullable *_Nullable error);
NS_ASSUME_NONNULL_END
