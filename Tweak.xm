#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "MediaManager.h"

#pragma mark 日志（设备无 syslog，状态只能写文件后远程读）
static NSString *g_logPath = nil;

static void VCamLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // 优先共享目录；沙盒里不可写时退回本 App 容器 tmp（必然可写，但仅本进程可见）
        NSArray<NSString *> *candidates = @[
            @"/var/jb/var/mobile/Library/VCam",
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCam"],
        ];
        NSString *dir = nil;
        for (NSString *c in candidates) {
            [fm createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:NULL];
            // 建得出来不代表写得进去（roothide 沙盒会拦），必须真写一个探针文件验证。
            // 否则会选中一个只读目录，日志全部静默丢失 —— 比没有日志更难查。
            NSString *probe = [c stringByAppendingPathComponent:@".probe"];
            if ([@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
                [fm removeItemAtPath:probe error:NULL];
                dir = c;
                break;
            }
        }
        if (!dir) dir = NSTemporaryDirectory();

        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"unknown";
        g_logPath = [dir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@.log", proc]];
    });
}

static void VCamLog(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);

    NSLog(@"[VCam] %@", msg);

    VCamLogInit();
    if (!g_logPath) return;

    @autoreleasepool {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [df stringFromDate:[NSDate date]], msg];

        @synchronized (g_logPath) {
            NSFileManager *fm = [NSFileManager defaultManager];
            if (![fm fileExistsAtPath:g_logPath]) {
                [line writeToFile:g_logPath atomically:YES
                         encoding:NSUTF8StringEncoding error:NULL];
                return;
            }
            // 控制体积：超过 256KB 只保留尾部
            NSDictionary *attr = [fm attributesOfItemAtPath:g_logPath error:NULL];
            if ([attr fileSize] > 256 * 1024) {
                NSString *old = [NSString stringWithContentsOfFile:g_logPath
                                                          encoding:NSUTF8StringEncoding
                                                             error:NULL];
                if (old.length > 64 * 1024) {
                    NSString *tail = [old substringFromIndex:old.length - 64 * 1024];
                    NSRange nl = [tail rangeOfString:@"\n"];
                    if (nl.location != NSNotFound) {
                        tail = [tail substringFromIndex:nl.location + 1];
                    }
                    [tail writeToFile:g_logPath atomically:YES
                             encoding:NSUTF8StringEncoding error:NULL];
                }
            }
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
            if (!fh) return;
            @try {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            } @finally {
                [fh closeFile];
            }
        }
    }
}

#pragma mark 悬浮穿透窗口 前置定义解决类型未识别报错
@interface VCamOverlayWindow : UIWindow
@end
@implementation VCamOverlayWindow
- (BOOL)isPointHitButtonArea:(CGPoint)point {
    if (!self.rootViewController) return NO;
    UIView *rootV = self.rootViewController.view;
    for (UIView *sub in rootV.subviews) {
        CGRect winRect = [sub convertRect:sub.bounds toView:self];
        if (CGRectContainsPoint(winRect, point)) return YES;
    }
    return NO;
}
// 除悬浮球以外的区域必须完全穿透，否则会吞掉整个 App 的点击。
// 关键：绝不能返回 self —— UIView.hitTest 在子视图都没命中时会兜底返回 self，
// 那样 overlay window 自身就成了命中视图，全屏拦截触摸（相机按钮点不动的根因）。
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (![self isPointHitButtonArea:point]) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}
@end

@interface VCamRootView : UIView
@end
@implementation VCamRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *sub in self.subviews) {
        CGPoint innerP = [self convertPoint:point toView:sub];
        if ([sub pointInside:innerP withEvent:event]) return sub;
    }
    return nil;
}
@end

@interface VCamFloatButton : UIButton
@property (nonatomic, assign) CGPoint initialCenter;
@end
@implementation VCamFloatButton
@end

#pragma mark 跨进程共享状态
// 相机 / 微信 / 相册选择器各自是独立进程，开关和视频原本只存在进程内的 static 里。
// 实测失败案例：在 A 应用里开启并选好视频，再打开系统相机 —— 相机进程的
// g_vcamEnabled 是 NO，它根本不知道别的进程开过，于是预览原样不动。
// 所以开关和视频必须落到一个各进程都够得着的共享位置。
//
// 候选目录按优先级排列，运行时用探针文件实测哪个真能写（各 App 沙盒放开程度不同）：
//   /var/tmp/VCam                权限 1777，实测相机进程就写在这里，最可靠
//   /var/jb/var/mobile/Library    roothide 的共享库目录
//   /var/mobile/Library          越狱传统共享位置
// 视频文件也必须复制过来：相册给的原始 URL 指向选择器自己的容器，别的进程读不到。
static NSArray *vcamSharedCandidates(void) {
    return @[
        @"/var/tmp/VCam",
        @"/var/jb/var/mobile/Library/VCam",
        @"/var/mobile/Library/VCam",
    ];
}

#pragma mark 全局变量
static NSMutableArray* g_allVideoDelegates = nil;
static BOOL g_vcamEnabled = NO;              // 本进程视角的开关，由共享状态驱动
static VCamOverlayWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static AVPlayer *g_maskPlayer = nil;
static AVPlayerLooper *g_looper = nil;       // 必须强引用，否则循环立刻失效
static NSURL *g_selectedVideoUrl = nil;      // 本进程选中的视频（原始 URL，仅供本进程用）
static NSString *g_playingPath = nil;        // 播放器当前加载的文件路径
static NSString *s_sharedDir = nil;          // 本进程实测可写的共享目录（记忆化）
static BOOL s_sharedDirProbed = NO;

// 相机预览层注册表。遮罩不再盖整屏，而是贴到每个 AVCaptureVideoPreviewLayer 上：
// 整屏遮罩有两个致命问题 —— 1) 猜不准该盖哪个 window（预览常在别的 window 上，
// 于是「视频在放、预览没变」）；2) 把相机自己的 UI 一起盖住，按钮全点不到。
// 贴在预览层上则天然对齐真实预览区域，且不遮挡 UI。
static NSHashTable *g_previewLayers = nil;    // weak：AVCaptureVideoPreviewLayer
static NSMapTable *g_previewOverlays = nil;   // weak key: 预览层 -> strong value: AVPlayerLayer

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);
static void vcamSyncPreviewOverlay(AVCaptureVideoPreviewLayer *layer);
static void vcamApplySharedState(void);
static void vcamWriteSharedState(BOOL enabled, NSString *videoPath);
static BOOL vcamReadSharedState(BOOL *enabled, NSString **path);

#pragma mark 录像替换
// 录像与拍照完全不同：AVCaptureMovieFileOutput 直接把编码后的数据写进 App 给的文件，
// 中途没有我们能插手的 sample buffer，所以只能事后覆盖 —— 记住目标 URL，
// 等录制结束、文件定型之后，把我们的视频拷过去。
static NSURL *g_recordingURL = nil;

// 代理类 -> 原 IMP。用 C 数组而不是 NSValue 存：本文件按 ObjC++ 编译，
// 函数指针与 void* 之间不能隐式转换，塞进 NSValue 需要一堆 reinterpret_cast。
#define VCAM_MAX_RECORD_HOOKS 8
static Class g_recordHookClasses[VCAM_MAX_RECORD_HOOKS] = {NULL};
static IMP   g_recordHookOrigs[VCAM_MAX_RECORD_HOOKS]   = {NULL};
static int   g_recordHookCount = 0;

// 把录下来的文件换成我们的视频。重复调用无害（目标已存在就先删再拷），
// 失败只记日志不抛，绝不能影响录像本身。
static void vcamReplaceRecordedFile(NSURL *url) {
    if (!g_vcamEnabled || g_playingPath.length == 0 || url.path.length == 0) return;

    NSError *err = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:url.path]) {
        [fm removeItemAtPath:url.path error:NULL];
    }
    if ([fm copyItemAtPath:g_playingPath toPath:url.path error:&err]) {
        VCamLog(@"录像替换生效：%@ <- %@", url.path, g_playingPath);
    } else {
        VCamLog(@"录像替换失败：%@", err.localizedDescription);
    }
}

// 代理的 didFinishRecording 回调 —— 此时文件已定型，是替换的安全时机
static void vcamDidFinishRecording(id self, SEL _cmd, AVCaptureFileOutput *output,
                                   NSURL *outputFileURL, AVCaptureConnection *connection,
                                   NSError *error) {
    vcamReplaceRecordedFile(outputFileURL);

    Class cls = object_getClass(self);
    IMP orig = NULL;
    for (; cls && !orig; cls = class_getSuperclass(cls)) {
        for (int i = 0; i < g_recordHookCount; i++) {
            if (g_recordHookClasses[i] == cls) {
                orig = g_recordHookOrigs[i];
                break;
            }
        }
    }
    if (orig) {
        ((void (*)(id, SEL, AVCaptureFileOutput *, NSURL *, AVCaptureConnection *, NSError *))orig)(
            self, _cmd, output, outputFileURL, connection, error);
    }
}

// 给录像代理的类装上回调 hook。代理类由 App 决定且事先不可知，
// 只能在 startRecording 时按实际对象动态安装。
static void vcamInstallRecordHook(Class cls) {
    if (!cls) return;

    for (int i = 0; i < g_recordHookCount; i++) {
        if (g_recordHookClasses[i] == cls) return;
    }
    if (g_recordHookCount >= VCAM_MAX_RECORD_HOOKS) return;

    NSString *key = NSStringFromClass(cls);
    SEL sel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnection:error:);
    if (!class_getInstanceMethod(cls, sel)) {
        VCamLog(@"录像代理 %@ 没实现 didFinishRecording，跳过 hook", key);
        return;
    }

    IMP orig = NULL;
    MSHookMessageEx(cls, sel, (IMP)vcamDidFinishRecording, &orig);
    if (orig) {
        g_recordHookClasses[g_recordHookCount] = cls;
        g_recordHookOrigs[g_recordHookCount] = orig;
        g_recordHookCount++;
        VCamLog(@"已给录像代理 %@ 装上 didFinishRecording hook", key);
    }
}

#pragma mark 预览层覆盖
// 正在同步的标记：addSublayer / 改 frame 都会让父层重新 layout，
// 进而再次回调 layoutSublayers，没有这个闩就会递归。
static BOOL s_syncingPreview = NO;

// 任意线程可调，内部统一切到主线程再动图层
static void vcamSyncPreviewOverlay(AVCaptureVideoPreviewLayer *layer) {
    if (!layer) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ vcamSyncPreviewOverlay(layer); });
        return;
    }
    if (s_syncingPreview) return;
    s_syncingPreview = YES;

    AVPlayerLayer *overlay = [g_previewOverlays objectForKey:layer];

    if (!g_vcamEnabled || !g_maskPlayer) {
        if (overlay) {
            [overlay removeFromSuperlayer];
            [g_previewOverlays removeObjectForKey:layer];
            VCamLog(@"预览层覆盖已移除 bounds=%@", NSStringFromCGRect(layer.bounds));
        }
        s_syncingPreview = NO;
        return;
    }

    if (!overlay) {
        overlay = [AVPlayerLayer playerLayerWithPlayer:g_maskPlayer];
        overlay.videoGravity = AVLayerVideoGravityResizeAspectFill;
        overlay.zPosition = 1000;
        overlay.frame = layer.bounds;
        [layer addSublayer:overlay];
        [g_previewOverlays setObject:overlay forKey:layer];
        VCamLog(@"已挂上预览层覆盖 layer=%p bounds=%@", layer,
                NSStringFromCGRect(layer.bounds));
    } else if (!CGRectEqualToRect(overlay.frame, layer.bounds)) {
        // 旋转 / 切前后摄 / 进画中画都会改预览层几何
        overlay.frame = layer.bounds;
        VCamLog(@"预览层几何已同步 bounds=%@", NSStringFromCGRect(layer.bounds));
    }

    s_syncingPreview = NO;
}

#pragma mark 共享状态读写

// 本进程实测可写的共享目录。forWrite=NO 时反过来找「已经存在状态文件」的那个（用于读）
static NSString *vcamSharedDir(BOOL forWrite) {
    if (forWrite && s_sharedDirProbed) return s_sharedDir;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *c in vcamSharedCandidates()) {
        [fm createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:NULL];
        // 目录得让别的进程也能进能读，否则状态写进去别人也取不到
        [fm setAttributes:@{NSFilePosixPermissions: @0777} ofItemAtPath:c error:NULL];

        if (!forWrite) {
            if ([fm fileExistsAtPath:[c stringByAppendingPathComponent:@"state.plist"]]) return c;
            continue;
        }
        // 建得出来不代表写得进去（沙盒按路径拦），必须真写探针文件
        NSString *probe = [c stringByAppendingPathComponent:@".probe"];
        if ([@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            [fm removeItemAtPath:probe error:NULL];
            s_sharedDirProbed = YES;
            s_sharedDir = c;
            VCamLog(@"共享目录选定：%@", c);
            return c;
        }
    }

    if (forWrite) {
        s_sharedDirProbed = YES;
        s_sharedDir = nil;
        VCamLog(@"没有可写的共享目录，开关只在本进程生效");
    }
    return nil;
}

// 读缓存。放在文件作用域是为了让写入方能主动失效它（见下）
static NSTimeInterval s_stateReadAt = 0;
static BOOL s_stateEnabled = NO;
static NSString *s_statePath = nil;

// 写完共享状态必须调这个：否则紧接着的读取会命中 0.5s 节流窗口里的旧值，
// 表现就是「刚点开启，本进程却没反应」，要等下一次同步才补上。
static void vcamInvalidateSharedStateCache(void) {
    s_stateReadAt = 0;
}

// 读共享状态。layoutSublayers 触发很频繁，节流 0.5s，免得每次布局都去碰文件
static BOOL vcamReadSharedState(BOOL *enabled, NSString **path) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - s_stateReadAt > 0.5) {
        s_stateReadAt = now;
        s_stateEnabled = NO;
        s_statePath = nil;
        for (NSString *c in vcamSharedCandidates()) {
            NSDictionary *st = [NSDictionary dictionaryWithContentsOfFile:
                                [c stringByAppendingPathComponent:@"state.plist"]];
            if (![st isKindOfClass:[NSDictionary class]]) continue;
            s_stateEnabled = [st[@"enabled"] boolValue];
            id p = st[@"videoPath"];
            if ([p isKindOfClass:[NSString class]]) s_statePath = [p copy];
            break;
        }
    }

    if (enabled) *enabled = s_stateEnabled;
    if (path) *path = s_statePath;
    return s_stateEnabled;
}

static void vcamWriteSharedState(BOOL enabled, NSString *videoPath) {
    NSString *dir = vcamSharedDir(YES);
    if (!dir) {
        VCamLog(@"无可写共享目录，开关仅本进程有效");
        return;
    }

    NSMutableDictionary *st = [NSMutableDictionary dictionary];
    st[@"enabled"] = @(enabled);
    if (videoPath) st[@"videoPath"] = videoPath;

    NSString *sp = [dir stringByAppendingPathComponent:@"state.plist"];
    BOOL ok = [st writeToFile:sp atomically:YES];
    // 别的进程要读得到，显式放宽读权限
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0644}
                                     ofItemAtPath:sp error:NULL];
    vcamInvalidateSharedStateCache();
    VCamLog(@"共享状态写入 enabled=%d path=%@ -> %@ ok=%d", enabled, videoPath, sp, ok);
}

#pragma mark 播放器与覆盖层

// 主线程
static void vcamTeardownPlayer(void) {
    if (g_maskPlayer) {
        [g_maskPlayer pause];
        g_maskPlayer = nil;
    }
    g_looper = nil;
    g_playingPath = nil;
}

// 主线程
static void vcamStartPlayer(NSString *path) {
    vcamTeardownPlayer();

    NSURL *url = [NSURL fileURLWithPath:path];
    // 变量名别叫 template —— 本文件按 ObjC++ 编译，那是 C++ 关键字
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithURL:url];

    // 循环用 AVPlayerLooper（配 AVQueuePlayer）。之前是自己监听
    // AVPlayerItemDidPlayToEndTimeNotification 再 seek 回零，实测播完就停 ——
    // 那个通知依赖 item 真的走到结尾，且 seek 与 play 的时序容易丢，
    // 交给系统这个专门做无缝循环的 API 更可靠。
    AVQueuePlayer *queuePlayer = [AVQueuePlayer queuePlayerWithItems:@[templateItem]];
    queuePlayer.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    g_looper = [AVPlayerLooper playerLooperWithPlayer:queuePlayer templateItem:templateItem];

    g_maskPlayer = queuePlayer;
    g_playingPath = [path copy];

    [g_maskPlayer play];
    VCamLog(@"开始播放（循环）%@（本进程已登记预览层 %lu 个）",
            path, (unsigned long)g_previewLayers.count);
}

#pragma mark 当前帧取样（拍照替换用）

// 拍到的仍是真实画面：预览层覆盖只改了「显示」，采集数据没动。
// 要改采集结果，只能在 App 取图时把它换掉 —— 见文件末尾 AVCapturePhoto 的 hook。
static AVAssetImageGenerator *g_imageGen = nil;
static NSString *g_imageGenPath = nil;
static CVPixelBufferRef g_lastFakePixelBuffer = NULL;

static AVAssetImageGenerator *vcamImageGenerator(void) {
    if (g_playingPath.length == 0) return nil;
    if (g_imageGen && [g_imageGenPath isEqualToString:g_playingPath]) return g_imageGen;

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:g_playingPath]];
    if (!asset) return nil;
    g_imageGen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    g_imageGen.appliesPreferredTrackTransform = YES;
    g_imageGen.requestedTimeToleranceBefore = kCMTimeZero;
    g_imageGen.requestedTimeToleranceAfter = kCMTimeZero;
    g_imageGenPath = [g_playingPath copy];
    return g_imageGen;
}

// 取播放头当前位置的那一帧。+1 的 CGImage，调用方负责 CGImageRelease；失败返回 NULL
static CGImageRef vcamCopyCurrentFrameImage(void) {
    AVAssetImageGenerator *gen = vcamImageGenerator();
    if (!gen) return NULL;

    CMTime t = g_maskPlayer ? g_maskPlayer.currentTime : kCMTimeZero;
    CGImageRef img = [gen copyCGImageAtTime:t actualTime:NULL error:NULL];
    // 播放头正好卡在结尾时会取不到，退回第一帧，总比让 App 拿到真图好
    if (!img) img = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    return img;
}

// CGImage -> JPEG。不走 UIImage（相关的便捷方法在这个 SDK 里不齐），
// 直接用 ImageIO。UTI 写死字符串而不引 kUTTypeJPEG：后者已废弃，
// 而本项目开了 -Werror，一个弃用警告就能让构建失败。
static NSData *vcamEncodeJPEG(CGImageRef img, CGFloat quality) {
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
    if (!dest) return nil;

    NSDictionary *opts = @{ (id)kCGImageDestinationLossyCompressionQuality: @(quality) };
    CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)opts);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? out : nil;
}

static NSData *vcamFakePhotoData(void) {
    if (!g_vcamEnabled || !g_maskPlayer || g_playingPath.length == 0) return nil;

    CGImageRef img = vcamCopyCurrentFrameImage();
    if (!img) {
        VCamLog(@"拍照替换：取当前帧失败，回退真实画面");
        return nil;
    }

    NSData *jpeg = vcamEncodeJPEG(img, 0.92);
    CGImageRelease(img);

    if (jpeg) {
        static BOOL logged = NO;
        if (!logged) {
            logged = YES;
            VCamLog(@"拍照替换生效：已返回假 JPEG %lu 字节", (unsigned long)jpeg.length);
        }
    }
    return jpeg;
}

static CVPixelBufferRef vcamFakePixelBuffer(void) {
    if (!g_vcamEnabled || !g_maskPlayer || g_playingPath.length == 0) return NULL;

    CGImageRef img = vcamCopyCurrentFrameImage();
    if (!img) return NULL;

    size_t w = CGImageGetWidth(img);
    size_t h = CGImageGetHeight(img);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
        CGImageRelease(img);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8,
                                             CVPixelBufferGetBytesPerRow(pb), cs,
                                             kCGImageAlphaPremultipliedFirst |
                                             kCGBitmapByteOrder32Little);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(img);

    // -pixelBuffer 这个方法名不表示调用方持有返回值，所以由我们保住这块 buffer，
    // 换新的时再释放旧的，避免每次拍照都漏一块。
    if (g_lastFakePixelBuffer) CVPixelBufferRelease(g_lastFakePixelBuffer);
    g_lastFakePixelBuffer = pb;
    return g_lastFakePixelBuffer;
}

// 主线程。读共享状态 → 对齐播放器 → 让每个预览层同步覆盖层。
// 这是唯一的状态入口：setSession / layoutSublayers / 回到前台 / 点按开关都汇到这里。
static BOOL s_applyingSharedState = NO;

static void vcamApplySharedState(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ vcamApplySharedState(); });
        return;
    }
    // 内部会 addSublayer，可能反过来触发 layoutSublayers 再回到这里；
    // 本函数全程在主线程，一个简单的闩就够，且外层那次调用已经把事情做完了。
    if (s_applyingSharedState) return;
    s_applyingSharedState = YES;

    BOOL enabled = NO;
    NSString *path = nil;
    vcamReadSharedState(&enabled, &path);

    BOOL wantPlay = enabled && path.length > 0 &&
                    [[NSFileManager defaultManager] fileExistsAtPath:path];

    if (wantPlay) {
        if (!g_maskPlayer || ![path isEqualToString:g_playingPath]) {
            vcamStartPlayer(path);
        }
    } else if (g_maskPlayer) {
        VCamLog(@"共享状态为关闭或视频读不到，停止播放");
        vcamTeardownPlayer();
    }

    g_vcamEnabled = (g_maskPlayer != nil);
    if (g_floatButton) {
        g_floatButton.backgroundColor = g_vcamEnabled
            ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
            : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
    }

    for (AVCaptureVideoPreviewLayer *l in g_previewLayers.allObjects) {
        vcamSyncPreviewOverlay(l);
    }

    s_applyingSharedState = NO;
}

static void setupFloatButton() {
    if (g_floatButton) return;
    CGFloat btnSize = 50;
    CGRect screen = [UIScreen mainScreen].bounds;

    g_floatButton = [VCamFloatButton buttonWithType:UIButtonTypeSystem];
    g_floatButton.frame = CGRectMake(screen.size.width - btnSize - 15, 100, btnSize, btnSize);
    g_floatButton.layer.cornerRadius = btnSize / 2.0;
    g_floatButton.layer.shadowColor = [UIColor blackColor].CGColor;
    g_floatButton.layer.shadowOffset = CGSizeMake(0, 2);
    g_floatButton.layer.shadowOpacity = 0.3;
    g_floatButton.layer.shadowRadius = 4;
    g_floatButton.backgroundColor = g_vcamEnabled
        ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9]
        : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
    [g_floatButton setTitle:@"📷" forState:UIControlStateNormal];
    g_floatButton.titleLabel.font = [UIFont systemFontOfSize:24];
    g_floatButton.layer.zPosition = 9999;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:g_floatButton action:@selector(handlePan:)];
    [g_floatButton addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:g_floatButton action:@selector(handleTap:)];
    [g_floatButton addGestureRecognizer:tap];

    g_overlayWindow = [[VCamOverlayWindow alloc] initWithFrame:screen];
    g_overlayWindow.windowLevel = UIWindowLevelStatusBar - 1;
    g_overlayWindow.hidden = NO;
    g_overlayWindow.backgroundColor = [UIColor clearColor];

    VCamRootView *rootView = [[VCamRootView alloc] initWithFrame:g_overlayWindow.bounds];
    rootView.backgroundColor = [UIColor clearColor];
    [rootView addSubview:g_floatButton];
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view = rootView;
    g_overlayWindow.rootViewController = rootVC;

    class_addMethod([g_floatButton class], @selector(handlePan:), (IMP)handlePanGesture, "v@:@");
    class_addMethod([g_floatButton class], @selector(handleTap:), (IMP)handleTapGesture, "v@:@");
}

static void handlePanGesture(UIPanGestureRecognizer *gesture) {
    UIView *btn = gesture.view;
    CGPoint translation = [gesture translationInView:btn.superview];
    btn.center = CGPointMake(btn.center.x + translation.x, btn.center.y + translation.y);
    [gesture setTranslation:CGPointZero inView:btn.superview];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        CGRect screen = [UIScreen mainScreen].bounds;
        CGFloat x = btn.center.x < screen.size.width / 2 ? 35 : screen.size.width - 35;
        [UIView animateWithDuration:0.2 animations:^{
            btn.center = CGPointMake(x, btn.center.y);
        }];
    }
}

static UIViewController *findTopViewController(void) {
    UIViewController *topVC = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        // connectedScenes 里不保证都是 UIWindowScene，而 -windows 只存在于 UIWindowScene。
        // 对普通 UIScene 取 .windows 是「向 UIResponder 发未实现消息」→ 未捕获异常 → SIGABRT。
        // 设备崩溃日志正是这个形状：_UIGestureRecognizerSendTargetActions → VCam.dylib
        // → 消息转发 → -[UIResponder doesNotRecognizeSelector:] → abort。
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) {
                topVC = w.rootViewController;
                break;
            }
        }
        if (topVC) break;
    }
    while (topVC && topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }
    return topVC;
}

#pragma mark 相册选择代理
@interface VCamImagePickerControllerDelegate : NSObject <UINavigationControllerDelegate, UIImagePickerControllerDelegate>
@end
@implementation VCamImagePickerControllerDelegate
- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSURL *srcUrl = info[UIImagePickerControllerMediaURL];
    if (!srcUrl) {
        VCamLog(@"相册回调里没有视频 URL，取消");
        return;
    }
    VCamLog(@"已选中视频 url=%@", srcUrl.path);
    g_selectedVideoUrl = srcUrl;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        [[MediaManager sharedManager] loadMediaFromURL:srcUrl];

        // 相册给的这个 URL 指向选择器自己的容器，别的进程没有读权限。
        // 必须复制一份到共享目录，否则「在这个应用里选完、打开相机」相机读不到文件。
        NSString *sharedVideo = nil;
        NSString *sharedDir = vcamSharedDir(YES);
        if (sharedDir) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *dst = [sharedDir stringByAppendingPathComponent:@"media.mov"];
            [fm removeItemAtPath:dst error:NULL];
            NSError *err = nil;
            if ([fm copyItemAtPath:srcUrl.path toPath:dst error:&err]) {
                [fm setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:dst error:NULL];
                sharedVideo = dst;
                VCamLog(@"视频已复制到共享位置 %@", dst);
            } else {
                VCamLog(@"复制视频到共享位置失败：%@", err.localizedDescription);
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [[MediaManager sharedManager] start];
            vcamWriteSharedState(YES, sharedVideo ?: srcUrl.path);
            vcamApplySharedState();
            VCamLog(@"视频已加载，虚拟相机开启");
        });
    });
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}
@end
static VCamImagePickerControllerDelegate *g_pickerDelegate = nil;

static void handleTapGesture(UITapGestureRecognizer *gesture) {
    UIViewController *topVC = findTopViewController();
    if (!topVC) {
        VCamLog(@"点按悬浮球：找不到 topViewController，忽略");
        return;
    }
    VCamLog(@"点按悬浮球 topVC=%@ enabled=%d", NSStringFromClass([topVC class]), g_vcamEnabled);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"VCam" message:g_vcamEnabled ? @"虚拟相机已启用" : @"虚拟相机已关闭" preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:@"选择视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeSavedPhotosAlbum]) {
            VCamLog(@"相册不可用，无法选择视频");
            return;
        }
        VCamLog(@"打开相册选视频");
        UIImagePickerController *picker = [[UIImagePickerController alloc] init];
        picker.sourceType = UIImagePickerControllerSourceTypeSavedPhotosAlbum;
        picker.mediaTypes = @[@"public.movie"];
        picker.delegate = g_pickerDelegate;
        [topVC presentViewController:picker animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:g_vcamEnabled ? @"关闭虚拟相机" : @"开启虚拟相机" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        BOOL target = !g_vcamEnabled;

        if (target) {
            [[MediaManager sharedManager] start];
            // 本进程没选过视频时，沿用共享状态里已有的那个 —— 开关和视频是两个独立的共享字段，
            // 不能因为这次没重新选片就把之前选好的视频丢掉。
            NSString *existing = nil;
            vcamReadSharedState(NULL, &existing);
            NSString *videoPath = g_selectedVideoUrl.path ?: existing;
            vcamWriteSharedState(YES, videoPath);
            if (!videoPath) {
                VCamLog(@"已开启，但哪儿都还没有选中的视频，预览不会被替换");
            }
        } else {
            [[MediaManager sharedManager] stop];
            vcamWriteSharedState(NO, nil);
        }

        vcamApplySharedState();
        VCamLog(@"虚拟相机开关切换：%d", target);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = gesture.view;
        alert.popoverPresentationController.sourceRect = gesture.view.bounds;
    }
    [topVC presentViewController:alert animated:YES completion:nil];
}

#pragma mark Hook分组（无私有框架）
%group VCamHooks
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    %orig;
    if (!g_allVideoDelegates) g_allVideoDelegates = [NSMutableArray array];
    if (delegate && ![g_allVideoDelegates containsObject:delegate]) {
        [g_allVideoDelegates addObject:delegate];
        VCamLog(@"捕获到 sampleBuffer delegate: %@ (共 %lu 个)",
                NSStringFromClass([delegate class]), (unsigned long)g_allVideoDelegates.count);
    }
}
%end

%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (g_vcamEnabled && [[MediaManager sharedManager] isRunning]) {
        static BOOL loggedHit = NO;
        if (!loggedHit) {
            loggedHit = YES;
            VCamLog(@"NSObject 层 hook 命中 output=%@", NSStringFromClass([output class]));
        }
        CMSampleBufferRef fakeFrame = [[MediaManager sharedManager] nextVideoFrame];
        if (fakeFrame) {
            for (id del in g_allVideoDelegates) {
                if ([del respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                    [del captureOutput:output didOutputSampleBuffer:fakeFrame fromConnection:connection];
                }
            }
            return;
        }
    }
    %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate { %orig; }
%end

// 拍照替换。AVCapturePhoto 几乎无法自行构造，只能改它的取值方法，
// 让 App 从它身上取到的图变成我们生成的。取不到假图时一律回退 %orig，
// 绝不能让拍照这个基础功能因为插件而失效。
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    NSData *fake = vcamFakePhotoData();
    if (fake) return fake;
    return %orig;
}
- (NSData *)fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer {
    NSData *fake = vcamFakePhotoData();
    if (fake) return fake;
    return %orig;
}
- (CVPixelBufferRef)pixelBuffer {
    CVPixelBufferRef fake = vcamFakePixelBuffer();
    if (fake) return fake;
    return %orig;
}
%end

// 录像替换。hook 基类 AVCaptureFileOutput，子类 AVCaptureMovieFileOutput 自然继承这个 override，
// 系统相机的普通录像和 QuickTake 都走这里。
%hook AVCaptureFileOutput
- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL
                    recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    g_recordingURL = outputFileURL;
    VCamLog(@"开始录像 -> %@", outputFileURL.path);
    vcamInstallRecordHook([delegate class]);
    %orig;
}
- (void)stopRecording {
    %orig;
    // 兜底：万一代理回调没装上，等文件定型后再补一次替换。
    // 重复替换无害，代价只是多拷一次文件。
    NSURL *target = g_recordingURL;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        vcamReplaceRecordedFile(target);
    });
}
%end

// 相机预览层：系统相机、微信视频通话等一切「把摄像头画面显示出来」的地方都经过它。
// 覆盖层贴在这里，替换的才是真正的预览区域 —— 而不是盲猜一个 window 去盖整屏。
%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    %orig;
    if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
    [g_previewLayers addObject:self];

    BOOL sharedOn = NO;
    NSString *sharedPath = nil;
    vcamReadSharedState(&sharedOn, &sharedPath);
    VCamLog(@"登记相机预览层 %p session=%p 共享开关=%d 共享视频=%@",
            self, session, sharedOn, sharedPath);

    // 这一步很关键：相机进程在这里才第一次知道「别的进程已经把虚拟相机打开了」
    vcamApplySharedState();
}
- (void)layoutSublayers {
    %orig;
    // 旋转 / 改尺寸 / 切前后摄会触发；同时也是回到前台后补同步的机会
    vcamApplySharedState();
}
%end
%end

#pragma mark 入口构造函数
%ctor {
    @autoreleasepool {
        g_pickerDelegate = [[VCamImagePickerControllerDelegate alloc] init];
        g_allVideoDelegates = nil;
        g_selectedVideoUrl = nil;
        // weak 持有预览层，避免拦住它的释放；覆盖层由我们强持有，预览层没了就跟着回收
        g_previewLayers = [NSHashTable weakObjectsHashTable];
        g_previewOverlays = [NSMapTable weakToStrongObjectsMapTable];

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        BOOL isSpringBoard = [bundleID isEqualToString:@"com.apple.springboard"];

        VCamLog(@"=== VCam 已加载 bundle=%@ pid=%d springboard=%d ===",
                bundleID, [NSProcessInfo processInfo].processIdentifier, isSpringBoard);
        VCamLog(@"日志路径=%@", g_logPath ?: @"(null)");

        if (!isSpringBoard) {
            %init(VCamHooks);
            VCamLog(@"VCamHooks 已初始化");
        } else {
            VCamLog(@"SpringBoard 内跳过 hooks 初始化");
        }

        // 在别的应用里开了开关再切回来时，预览层不会重新 setSession，
        // layoutSublayers 也不一定触发，靠回到前台这一下补同步。
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            vcamApplySharedState();
        }];

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @autoreleasepool {
                setupFloatButton();
                VCamLog(@"悬浮球已创建");
            }
        });
    }
}
