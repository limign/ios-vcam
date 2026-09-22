#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <substrate.h>

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

// 动态 hook 的登记表。代理类由 App 决定、事先不可知，只能拿到对象后再按实际类装。
// 用 C 数组而不是 NSValue 存：本文件按 ObjC++ 编译，函数指针与 void* 之间不能
// 隐式转换，塞 NSValue 需要一堆 reinterpret_cast。
#define VCAM_MAX_HOOKS 8
typedef struct { Class cls; IMP orig; } VCamHookSlot;
static VCamHookSlot g_hookSlots[VCAM_MAX_HOOKS];
static int g_hookCount = 0;

static BOOL vcamIsHooked(Class cls) {
    for (int i = 0; i < g_hookCount; i++) {
        if (g_hookSlots[i].cls == cls) return YES;
    }
    return NO;
}

static BOOL vcamRememberHook(Class cls, IMP orig) {
    if (!cls || !orig || g_hookCount >= VCAM_MAX_HOOKS) return NO;
    g_hookSlots[g_hookCount].cls = cls;
    g_hookSlots[g_hookCount].orig = orig;
    g_hookCount++;
    return YES;
}

// 沿继承链找这个对象所属类被 hook 时记下的原 IMP
static IMP vcamLookupOrig(id obj) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        for (int i = 0; i < g_hookCount; i++) {
            if (g_hookSlots[i].cls == c) return g_hookSlots[i].orig;
        }
    }
    return NULL;
}

// 找到真正实现 sel 的那一层类并 hook。不能直接拿 class_getInstanceMethod 的结果
// 去下手：它返回的是继承来的方法，会给一个本来没实现该方法的类平白加上一个方法，
// 拿到的原 IMP 也不是那一层自己的。所以要逐层比对实现指针，只挑"和父类不同"的层。
static BOOL vcamHookImplementation(id obj, SEL sel, IMP hook) {
    if (!obj) return NO;
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        Method m = class_getInstanceMethod(c, sel);
        if (!m) return NO;
        Method up = class_getInstanceMethod(class_getSuperclass(c), sel);
        if (!up || method_getImplementation(m) != method_getImplementation(up)) {
            if (vcamIsHooked(c)) return YES;
            IMP orig = NULL;
            MSHookMessageEx(c, sel, hook, &orig);
            return vcamRememberHook(c, orig);
        }
    }
    return NO;
}

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

    IMP orig = vcamLookupOrig(self);
    if (orig) {
        ((void (*)(id, SEL, AVCaptureFileOutput *, NSURL *, AVCaptureConnection *, NSError *))orig)(
            self, _cmd, output, outputFileURL, connection, error);
    }
}

// 给录像代理装上回调 hook，按实际对象的类动态安装。
static void vcamInstallRecordHook(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnection:error:);
    if (!class_getInstanceMethod(cls, sel)) {
        VCamLog(@"录像代理 %@ 没实现 didFinishRecording，跳过 hook", NSStringFromClass(cls));
        return;
    }
    if (vcamHookImplementation(delegate, sel, (IMP)vcamDidFinishRecording)) {
        VCamLog(@"已给录像代理 %@ 装上 didFinishRecording hook", NSStringFromClass(cls));
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

// 采集注入用的帧缓存（+1 持有）。视频一换就作废。
// 它是 CF 对象、引用计数由我们手管，而采集回调在 App 的采集队列上、作废在主线程上，
// 所以这里必须上锁 —— 否则换视频时可能把它释放两次。
static CGImageRef g_bufFrameCache = NULL;
static CMTime g_bufFrameCacheTime = kCMTimeInvalid;

static NSLock *vcamFrameCacheLock(void) {
    static NSLock *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSLock alloc] init]; });
    return lock;
}

// 主线程
static void vcamTeardownPlayer(void) {
    if (g_maskPlayer) {
        [g_maskPlayer pause];
        g_maskPlayer = nil;
    }
    g_looper = nil;
    g_playingPath = nil;

    NSLock *lock = vcamFrameCacheLock();
    [lock lock];
    if (g_bufFrameCache) {
        CGImageRelease(g_bufFrameCache);
        g_bufFrameCache = NULL;
    }
    g_bufFrameCacheTime = kCMTimeInvalid;
    [lock unlock];
}

// 主线程
static void vcamStartPlayer(NSString *path) {
    vcamTeardownPlayer();

    NSURL *url = [NSURL fileURLWithPath:path];
    // 变量名别叫 template —— 本文件按 ObjC++ 编译，那是 C++ 关键字
    AVPlayerItem *templateItem = [AVPlayerItem playerItemWithURL:url];

    // 循环用 AVPlayerLooper。队列必须建造成空的：looper 只把 templateItem 当模板，
    // 自己往队列里插副本（文档原话是它不会参与实际播放）。上一版把 templateItem
    // 塞进 queuePlayerWithItems: 一起交出去，结果队列里那个只当模板的 item 反而
    // 排在前面，画面就定在第一帧不动 —— 所以这里改成空队列。
    AVQueuePlayer *queuePlayer = [[AVQueuePlayer alloc] init];
    queuePlayer.actionAtItemEnd = AVPlayerActionAtItemEndAdvance;
    g_looper = [AVPlayerLooper playerLooperWithPlayer:queuePlayer templateItem:templateItem];

    g_maskPlayer = queuePlayer;
    g_playingPath = [path copy];

    [g_maskPlayer play];

    // 起播后回看一眼。画面定格这种毛病光看"开始播放"那行是分不出来的：
    // items 里到底有没有 looper 插进去的副本、rate 有没有真起来，得拉出来看。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_maskPlayer != queuePlayer) return;    // 这期间被换掉或关掉了

        AVQueuePlayer *qp = (AVQueuePlayer *)g_maskPlayer;
        VCamLog(@"播放器回看 items=%lu rate=%.1f（item 本身 status=%ld）",
                (unsigned long)qp.items.count, (double)g_maskPlayer.rate,
                (long)templateItem.status);
        if (qp.items.count > 0 && g_maskPlayer.rate > 0.0) return;

        // looper 没把副本放进队列，或者播放器压根没起来。退回普通播放器：
        // 画面定格不动比"只播一遍"严重得多，先保证它是动的。
        VCamLog(@"looper 未生效，退回普通播放器（不循环）");
        g_looper = nil;
        AVPlayer *plain = [AVPlayer playerWithURL:url];
        g_maskPlayer = plain;
        [plain play];
    });

    VCamLog(@"开始播放（循环）%@（本进程已登记预览层 %lu 个）",
            path, (unsigned long)g_previewLayers.count);
}

#pragma mark 当前帧取样

// 拍到的仍是真实画面：预览层覆盖只改了「显示」，采集数据没动。
// 要改采集结果，得在采集链路上把帧换掉 —— 见下面「采集帧注入」一节。
static AVAssetImageGenerator *g_imageGen = nil;
static NSString *g_imageGenPath = nil;
static AVAssetImageGenerator *g_bufGen = nil;      // 采集注入专用：限了尺寸，每帧都要跑
static NSString *g_bufGenPath = nil;
static CVPixelBufferRef g_lastFakePixelBuffer = NULL;

static AVAssetImageGenerator *vcamMakeGenerator(CGFloat maxSide) {
    if (g_playingPath.length == 0) return nil;

    AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:g_playingPath]];
    if (!asset) return nil;
    AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    gen.appliesPreferredTrackTransform = YES;
    if (maxSide > 0) {
        gen.maximumSize = CGSizeMake(maxSide, maxSide);
    } else {
        // 拍照要的是成品，取精确帧
        gen.requestedTimeToleranceBefore = kCMTimeZero;
        gen.requestedTimeToleranceAfter = kCMTimeZero;
    }
    return gen;
}

static AVAssetImageGenerator *vcamImageGenerator(void) {
    if (g_imageGen && [g_imageGenPath isEqualToString:g_playingPath]) return g_imageGen;
    g_imageGen = vcamMakeGenerator(0);
    g_imageGenPath = g_playingPath ? [g_playingPath copy] : nil;
    return g_imageGen;
}

// 采集路径每帧都要取一次图，解码成本必须压住：限到 960x540（假画面够看了）
// 并允许 ±1/15 秒的取帧误差，这样生成器能就近取帧而不必精确解码每一帧。
static AVAssetImageGenerator *vcamBufferImageGenerator(void) {
    if (g_bufGen && [g_bufGenPath isEqualToString:g_playingPath]) return g_bufGen;
    g_bufGen = vcamMakeGenerator(960);
    if (g_bufGen) {
        g_bufGen.requestedTimeToleranceBefore = CMTimeMake(1, 15);
        g_bufGen.requestedTimeToleranceAfter = CMTimeMake(1, 15);
    }
    g_bufGenPath = g_playingPath ? [g_playingPath copy] : nil;
    return g_bufGen;
}

// 取指定生成器在播放头位置的帧。+1 的 CGImage，调用方负责 CGImageRelease
static CGImageRef vcamCopyFrameFrom(AVAssetImageGenerator *gen) {
    if (!gen) return NULL;

    CMTime t = g_maskPlayer ? g_maskPlayer.currentTime : kCMTimeZero;
    CGImageRef img = [gen copyCGImageAtTime:t actualTime:NULL error:NULL];
    // 播放头正好卡在结尾时会取不到，退回第一帧，总比让 App 拿到真图好
    if (!img) img = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    return img;
}

static CGImageRef vcamCopyCurrentFrameImage(void) {
    return vcamCopyFrameFrom(vcamImageGenerator());
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

#pragma mark 像素缓冲工具

static CVPixelBufferRef vcamCreatePixelBuffer(size_t w, size_t h, OSType pf) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, pf,
                            (__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess) {
        return NULL;
    }
    return pb;
}

// 等比放大到铺满，超出部分裁掉 —— 相机画面被拉伸变形会很怪，宁可靠边裁
static void vcamDrawFilling(CGContextRef ctx, CGImageRef img, size_t w, size_t h) {
    CGFloat iw = (CGFloat)CGImageGetWidth(img);
    CGFloat ih = (CGFloat)CGImageGetHeight(img);
    if (iw <= 0 || ih <= 0) return;
    CGFloat scale = MAX((CGFloat)w / iw, (CGFloat)h / ih);
    CGContextDrawImage(ctx, CGRectMake(((CGFloat)w - iw * scale) / 2.0,
                                       ((CGFloat)h - ih * scale) / 2.0,
                                       iw * scale, ih * scale), img);
}

static BOOL vcamDrawIntoBGRAPixelBuffer(CVPixelBufferRef pb, CGImageRef img) {
    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) return NO;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8,
                                            CVPixelBufferGetBytesPerRow(pb), cs,
                                            kCGImageAlphaPremultipliedFirst |
                                            kCGBitmapByteOrder32Little);
    BOOL ok = (ctx != NULL);
    if (ok) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
        vcamDrawFilling(ctx, img, w, h);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return ok;
}

// BGRA -> 420 双平面。手写而不是引 vImage：少一个框架依赖，也省掉核对那堆
// vImage 签名（本项目 -Werror，签名叫错一次就是一轮构建白跑）。
// 420v 是视频范围（16-235），420f 是全范围，系数不同 —— 用反了暗部会被压死，
// 而且我们复用的是原始 format description，解码方不会替我们纠偏。
static void vcamConvertBGRAto420(CVPixelBufferRef src, CVPixelBufferRef dst, BOOL fullRange) {
    size_t w = CVPixelBufferGetWidth(dst);
    size_t h = CVPixelBufferGetHeight(dst);
    uint8_t *Y = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 0);
    size_t Ys = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
    uint8_t *C = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 1);
    size_t Cs = CVPixelBufferGetBytesPerRowOfPlane(dst, 1);
    const uint8_t *S = (const uint8_t *)CVPixelBufferGetBaseAddress(src);
    size_t Ss = CVPixelBufferGetBytesPerRow(src);
    if (!Y || !C || !S) return;

    const int yR = fullRange ? 77 : 66;
    const int yG = fullRange ? 150 : 129;
    const int yB = fullRange ? 29 : 25;
    const int yRound = fullRange ? 0 : 128;
    const int yBias = fullRange ? 0 : 16;

    for (size_t y = 0; y < h; y++) {
        const uint8_t *s = S + y * Ss;
        uint8_t *d = Y + y * Ys;
        for (size_t x = 0; x < w; x++) {
            int b = s[x * 4 + 0], g = s[x * 4 + 1], r = s[x * 4 + 2];
            int v = ((yR * r + yG * g + yB * b + yRound) >> 8) + yBias;
            d[x] = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
        }
    }

    size_t cw = (w + 1) / 2;
    size_t ch = (h + 1) / 2;
    for (size_t cy = 0; cy < ch; cy++) {
        uint8_t *d = C + cy * Cs;
        for (size_t cx = 0; cx < cw; cx++) {
            int rs = 0, gs = 0, bs = 0, n = 0;
            for (size_t dy = 0; dy < 2; dy++) {
                size_t yy = cy * 2 + dy;
                if (yy >= h) break;
                const uint8_t *s = S + yy * Ss;
                for (size_t dx = 0; dx < 2; dx++) {
                    size_t xx = cx * 2 + dx;
                    if (xx >= w) break;
                    bs += s[xx * 4 + 0];
                    gs += s[xx * 4 + 1];
                    rs += s[xx * 4 + 2];
                    n++;
                }
            }
            if (!n) continue;
            int r = rs / n, g = gs / n, b = bs / n;
            int cb = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
            int cr = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
            d[cx * 2 + 0] = (uint8_t)(cb < 0 ? 0 : (cb > 255 ? 255 : cb));
            d[cx * 2 + 1] = (uint8_t)(cr < 0 ? 0 : (cr > 255 ? 255 : cr));
        }
    }
}

static CVPixelBufferRef vcamFakePixelBuffer(void) {
    if (!g_vcamEnabled || !g_maskPlayer || g_playingPath.length == 0) return NULL;

    CGImageRef img = vcamCopyCurrentFrameImage();
    if (!img) return NULL;

    size_t w = CGImageGetWidth(img);
    size_t h = CGImageGetHeight(img);
    CVPixelBufferRef pb = vcamCreatePixelBuffer(w, h, kCVPixelFormatType_32BGRA);
    if (!pb || !vcamDrawIntoBGRAPixelBuffer(pb, img)) {
        if (pb) CVPixelBufferRelease(pb);
        CGImageRelease(img);
        return NULL;
    }
    CGImageRelease(img);

    // -pixelBuffer 这个方法名不表示调用方持有返回值，所以由我们保住这块 buffer，
    // 换新的时再释放旧的，避免每次拍照都漏一块。
    if (g_lastFakePixelBuffer) CVPixelBufferRelease(g_lastFakePixelBuffer);
    g_lastFakePixelBuffer = pb;
    return g_lastFakePixelBuffer;
}

#pragma mark 采集帧注入（拍照与录像的真正数据源）

// 这一节是被实测逼出来的。原设计在 AVCapturePhoto 的取值方法上做手脚，日志证明
// 它确实被调用了（"拍照替换生效：已返回假 JPEG"），但存进相册的仍是真实画面；
// 与此同时 AVCaptureFileOutput 的 startRecording 一次都没被调用过 —— 系统相机
// 根本不用 AVCaptureMovieFileOutput。真正出现的是 CAMCaptureEngine 以
// sampleBuffer 代理的身份注册在 AVCaptureVideoDataOutput 上。
// 也就是说：拍照和录像的字节都从 sample buffer 流出去，由 App 自己用 AVAssetWriter
// 写文件（RosyWriter 那套）。所以必须在源头把帧换掉 —— 换在这里，拍照、录像、
// 以后要支持的第三方 App 通话，一次性全覆盖。
static CGImageRef vcamCopyBufferFrameImage(void) {
    AVAssetImageGenerator *gen = vcamBufferImageGenerator();
    if (!gen) return NULL;

    CMTime t = g_maskPlayer ? g_maskPlayer.currentTime : kCMTimeZero;

    // 采集回调往往比视频帧率还密，播放头没动就没必要重新解码
    NSLock *lock = vcamFrameCacheLock();
    [lock lock];
    CGImageRef cached = NULL;
    if (g_bufFrameCache && CMTIME_IS_VALID(g_bufFrameCacheTime) &&
        CMTimeCompare(CMTimeAbsoluteValue(CMTimeSubtract(t, g_bufFrameCacheTime)),
                      CMTimeMake(1, 30)) < 0) {
        cached = CGImageRetain(g_bufFrameCache);
    }
    [lock unlock];
    if (cached) return cached;

    CGImageRef img = vcamCopyFrameFrom(gen);   // 解码不持锁，别让主线程陪着等
    if (img) {
        [lock lock];
        if (g_bufFrameCache) CGImageRelease(g_bufFrameCache);
        g_bufFrameCache = CGImageRetain(img);
        g_bufFrameCacheTime = t;
        [lock unlock];
    }
    return img;
}

// 造一个与真实帧同尺寸同格式的假帧，再包成 CMSampleBuffer。
// format description 直接沿用原始的，所以下游（编码器/写入器）看到的仍然是它认识
// 的那个格式，不需要为我们的替换改任何设置。任何一步不对就返回 NULL，调用方原样
// 放行真实帧 —— 插件不能把相机本身搞坏。
static CMSampleBufferRef vcamMakeFakeSampleBuffer(AVCaptureOutput *output, CMSampleBufferRef orig) {
    if (!g_vcamEnabled || g_playingPath.length == 0) return NULL;
    if (![output isKindOfClass:[AVCaptureVideoDataOutput class]]) return NULL;

    CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(orig);
    if (!origPB) return NULL;      // 音频等没有图像平面的，一律放行

    size_t w = CVPixelBufferGetWidth(origPB);
    size_t h = CVPixelBufferGetHeight(origPB);
    OSType pf = CVPixelBufferGetPixelFormatType(origPB);
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(orig);
    if (!w || !h || !fmt) return NULL;

    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(orig, 0, &timing) != noErr) return NULL;

    CGImageRef img = vcamCopyBufferFrameImage();
    if (!img) return NULL;

    CVPixelBufferRef pb = NULL;
    if (pf == kCVPixelFormatType_32BGRA) {
        pb = vcamCreatePixelBuffer(w, h, pf);
        if (pb && !vcamDrawIntoBGRAPixelBuffer(pb, img)) {
            CVPixelBufferRelease(pb);
            pb = NULL;
        }
    } else if (pf == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
               pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        CVPixelBufferRef rgb = vcamCreatePixelBuffer(w, h, kCVPixelFormatType_32BGRA);
        if (rgb) {
            if (vcamDrawIntoBGRAPixelBuffer(rgb, img)) {
                pb = vcamCreatePixelBuffer(w, h, pf);
                if (pb) {
                    CVPixelBufferLockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
                    CVPixelBufferLockBaseAddress(pb, 0);
                    vcamConvertBGRAto420(rgb, pb,
                        pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
                    CVPixelBufferUnlockBaseAddress(pb, 0);
                    CVPixelBufferUnlockBaseAddress(rgb, kCVPixelBufferLock_ReadOnly);
                }
            }
            CVPixelBufferRelease(rgb);
        }
    }
    CGImageRelease(img);

    if (!pb) {
        static int loggedPf = 0;
        if (loggedPf != (int)pf) {
            loggedPf = (int)pf;
            VCamLog(@"采集帧格式 %u 暂不支持替换，真实帧放行", (unsigned)pf);
        }
        return NULL;
    }

    CMSampleBufferRef out = NULL;
    OSStatus st = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb, true, NULL, NULL,
                                                     fmt, &timing, &out);
    CVPixelBufferRelease(pb);
    if (st != noErr || !out) {
        VCamLog(@"替换 sample buffer 构建失败 st=%d", (int)st);
        return NULL;
    }

    static BOOL logged = NO;
    if (!logged) {
        logged = YES;
        VCamLog(@"采集帧注入生效：%lux%lu pf=%u",
                (unsigned long)w, (unsigned long)h, (unsigned)pf);
    }
    return out;    // +1，调用方负责 CFRelease
}

// 代理的采集回调。这是我们唯一能改到"真正被写进文件的那份数据"的地方。
static void vcamDidOutputSampleBuffer(id self, SEL _cmd, AVCaptureOutput *output,
                                      CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    IMP orig = vcamLookupOrig(self);
    if (!orig) return;      // 没记到原实现就什么都不做，绝不吞掉这一帧

    CMSampleBufferRef fake = vcamMakeFakeSampleBuffer(output, sampleBuffer);
    ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))orig)(
        self, _cmd, output, fake ? fake : sampleBuffer, connection);
    if (fake) CFRelease(fake);
}

static void vcamInstallSampleBufferHook(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    if (!class_getInstanceMethod(cls, sel)) {
        VCamLog(@"sampleBuffer 代理 %@ 没实现 didOutput，跳过", NSStringFromClass(cls));
        return;
    }
    if (vcamHookImplementation(delegate, sel, (IMP)vcamDidOutputSampleBuffer)) {
        VCamLog(@"已给 sampleBuffer 代理 %@ 装上注入 hook", NSStringFromClass(cls));
    }
}

#pragma mark 假 CGImage（AVCapturePhoto 的另一条取值路径）

// AVCapturePhoto 的约定是 CGImage 由它自己持有、调用方不释放，所以我们也自己攥着，
// 下次再换时释放旧的。
static CGImageRef g_lastFakeCGImage = NULL;

static CGImageRef vcamFakeCGImage(void) {
    if (!g_vcamEnabled || !g_maskPlayer || g_playingPath.length == 0) return NULL;

    CGImageRef src = vcamCopyCurrentFrameImage();
    if (!src) return NULL;

    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
                                            kCGImageAlphaPremultipliedFirst |
                                            kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);

    CGImageRef out = NULL;
    if (ctx) {
        vcamDrawFilling(ctx, src, w, h);
        out = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
    }
    CGImageRelease(src);

    if (out) {
        if (g_lastFakeCGImage) CGImageRelease(g_lastFakeCGImage);
        g_lastFakeCGImage = out;
    }
    return g_lastFakeCGImage;
}

// 诊断用：设备上没有 syslog，只能靠日志。同一件事只记一次，免得刷屏。
static void VCamLogOnce(NSString *tag, NSString *msg) {
    static NSMutableSet *seen = nil;
    if (!seen) seen = [NSMutableSet set];
    if ([seen containsObject:tag]) return;
    [seen addObject:tag];
    VCamLog(@"%@", msg);
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
    // 代理类由 App 决定（系统相机是 CAMCaptureEngine），事先不可知，
    // 只能等它注册上来的时候按实际类装 hook。
    VCamLog(@"捕获到 sampleBuffer 代理 %@", NSStringFromClass(object_getClass(delegate)));
    vcamInstallSampleBufferHook(delegate);
}
%end

%hook AVCaptureSession
- (void)startRunning { %orig; }
- (void)stopRunning { %orig; }
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    // processedFileType 的类型在 SDK 里是 AVFileType（NSString*），但为免记错类型
    // 直接把整数当对象打出来会崩，这里走 KVC 取值 —— 不管它到底是什么都会被装成对象。
    NSString *key = [NSString stringWithFormat:@"photoDelegate:%@", NSStringFromClass(object_getClass(delegate))];
    VCamLogOnce(key, [NSString stringWithFormat:@"拍照代理 %@ fileType=%@ uniqueID=%lld",
                      NSStringFromClass(object_getClass(delegate)),
                      [settings valueForKey:@"processedFileType"],
                      (long long)settings.uniqueID]);
    %orig;
}
%end

// 拍照替换。AVCapturePhoto 几乎无法自行构造，只能改它的取值方法，
// 让 App 从它身上取到的图变成我们生成的。取不到假图时一律回退 %orig，
// 绝不能让拍照这个基础功能因为插件而失效。
// 注：实测这几条对系统相机不够（真正被写进文件的是采集链路上的帧，见「采集帧注入」），
// 但对直接用 AVCapturePhotoOutput 取图的第三方 App 仍然有效，所以留着。
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    VCamLogOnce(@"photo:fileData", @"相机在取 fileDataRepresentation");
    NSData *fake = vcamFakePhotoData();
    if (fake) return fake;
    return %orig;
}
- (NSData *)fileDataRepresentationWithCustomizer:(id<AVCapturePhotoFileDataRepresentationCustomizer>)customizer {
    VCamLogOnce(@"photo:fileDataCustomizer", @"相机在取 fileDataRepresentationWithCustomizer");
    NSData *fake = vcamFakePhotoData();
    if (fake) return fake;
    return %orig;
}
- (CVPixelBufferRef)pixelBuffer {
    VCamLogOnce(@"photo:pixelBuffer", @"相机在取 pixelBuffer");
    CVPixelBufferRef fake = vcamFakePixelBuffer();
    if (fake) return fake;
    return %orig;
}
- (CGImageRef)CGImageRepresentation {
    VCamLogOnce(@"photo:cgImage", @"相机在取 CGImageRepresentation");
    CGImageRef fake = vcamFakeCGImage();
    if (fake) return fake;
    return %orig;
}
%end

// 录像替换。hook 基类 AVCaptureFileOutput，子类 AVCaptureMovieFileOutput 自然继承这个 override。
// 实测系统相机不走这条路（日志里 startRecording 一次都没出现），留着是为了第三方 App。
%hook AVCaptureFileOutput
- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL
                    recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    g_recordingURL = outputFileURL;
    VCamLog(@"开始录像 -> %@", outputFileURL.path);
    vcamInstallRecordHook(delegate);
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
