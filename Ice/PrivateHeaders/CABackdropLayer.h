//
//  CABackdropLayer.h
//  Ice
//
//  Reconstructed from the compiled binary of the 2026-09-02 build.
//
//  The binary references the ObjC class `CABackdropLayer` as an *external* symbol
//  (`_OBJC_CLASS_$_CABackdropLayer` is undefined in the dylib, and the stored
//  property mangles to `So15CABackdropLayerC`). That is only possible if the class
//  was declared to Swift through a bridging header, so the original working copy
//  must have carried one. QuartzCore ships this class privately and the SDK exposes
//  no header for it, so we declare it ourselves. This is a declaration only — the
//  implementation lives in QuartzCore and is resolved at runtime.
//

#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

/// The private layer class that Core Animation uses to composite the backdrop
/// of a visual effect view.
@interface CABackdropLayer : CALayer
@end

NS_ASSUME_NONNULL_END
