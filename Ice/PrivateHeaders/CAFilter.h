//
//  CAFilter.h
//  Ice
//
//  Declares the private Core Animation filter class that layer filters are built
//  from. QuartzCore ships the class privately and the SDK exposes no header for it,
//  so we declare it ourselves, exactly as this project does for CABackdropLayer.
//  This is a declaration only — the implementation lives in QuartzCore and is
//  resolved at runtime.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The private Core Animation filter accepted by `CALayer.filters` and
/// `CALayer.compositingFilter`.
///
/// A filter's inputs are set with key value coding, which is how Core Animation
/// itself addresses them (`inputAmount`, `inputAngle`, and so on).
@interface CAFilter : NSObject <NSCopying, NSMutableCopying, NSSecureCoding>

/// Creates a filter of the given type.
+ (instancetype)filterWithType:(NSString *)type;

/// Creates a filter of the given type.
- (instancetype)initWithType:(NSString *)type;

/// The name of the filter.
@property (nullable, copy) NSString *name;

@end

NS_ASSUME_NONNULL_END
