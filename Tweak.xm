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
        // 顺序说明：/var/jb/... 是越狱原生位置（最干净，但 roothide 沙盒里多数 App 写不进去）；
        // /var/tmp/VCam 是共享目录 —— 这条是补上的关键一条：相机 App 原来两个候选位置全被拒
        // （系统 App 没有可写的容器 tmp），于是相机进程一条日志都没留下。而虚拟相机真正要动
        // 的采集/写入/元数据全发生在相机进程里 —— 没有相机侧的日志就只能靠猜，
        // 已经猜错过三次了。共享目录里的 state.plist 本来就是相机那边写成功的，说明它写得进去。
        // 最后仍然退回本进程容器 tmp（必然可写，但只有本进程看得见）。
        NSArray<NSString *> *candidates = @[
            @"/var/jb/var/mobile/Library/VCam",
            @"/var/tmp/VCam",
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

// 定义在后面，但采集注入那一段要用它 —— 少了这行声明就是隐式声明，-Werror 直接卡构建
static void VCamLogOnce(NSString *tag, NSString *msg);

// 同理。它的定义在"采集拓扑诊断"那一段（要看 vcamLogThrottle 等），
// 但播放器那一段要用它按 KVC 取结构体属性。C++ 里没有隐式函数声明，缺了这行直接卡构建。
static id vcamValueIfResponds(id obj, SEL sel);

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
static id g_timeObserver = nil;              // 循环用的定时观察者；拆播放器前必须先摘掉
static id g_endObserver = nil;               // "播到结尾"通知，循环的兜底
static int g_playerTicks = 0;                // 时钟走过几拍 —— 画面到底动没动，只有这个是硬证据
static NSURL *g_selectedVideoUrl = nil;      // 本进程选中的视频（原始 URL，仅供本进程用）
static NSString *g_playingPath = nil;        // 播放器当前加载的文件路径
static NSString *g_requestedPhotoType = nil; // App 这次拍照要的文件类型（public.heic 等）
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
#define VCAM_MAX_HOOKS 24
// 记的是 (类, 选择器) 这一对，不是只记类。同一条采集链上我们会在一个类里挂好几个
// 方法（比如录像的 startRecording 和 stopRecording），只按类记的话后一个会拿到前一个
// 的原 IMP，按错签名调下去就是崩溃。
typedef struct { Class cls; SEL sel; IMP orig; } VCamHookSlot;
static VCamHookSlot g_hookSlots[VCAM_MAX_HOOKS];
static int g_hookCount = 0;

static BOOL vcamIsHooked(Class cls) {
    for (int i = 0; i < g_hookCount; i++) {
        if (g_hookSlots[i].cls == cls) return YES;
    }
    return NO;
}

static BOOL vcamIsHookedFor(Class cls, SEL sel) {
    for (int i = 0; i < g_hookCount; i++) {
        if (g_hookSlots[i].cls == cls && sel_isEqual(g_hookSlots[i].sel, sel)) return YES;
    }
    return NO;
}

static BOOL vcamRememberHook(Class cls, SEL sel, IMP orig) {
    if (!cls || !sel || !orig || g_hookCount >= VCAM_MAX_HOOKS) return NO;
    g_hookSlots[g_hookCount].cls = cls;
    g_hookSlots[g_hookCount].sel = sel;
    g_hookSlots[g_hookCount].orig = orig;
    g_hookCount++;
    return YES;
}

// 沿继承链找 (类, sel) 被 hook 时记下的原 IMP。_cmd 传进来就是当前选择器，
// 所以同一个回调函数可以服务多个方法。
static IMP vcamLookupOrig(id obj, SEL sel) {
    for (Class c = object_getClass(obj); c; c = class_getSuperclass(c)) {
        for (int i = 0; i < g_hookCount; i++) {
            if (g_hookSlots[i].cls == c && sel_isEqual(g_hookSlots[i].sel, sel)) {
                return g_hookSlots[i].orig;
            }
        }
    }
    return NULL;
}

// 找到真正实现 sel 的那一层类并 hook。不能直接拿 class_getInstanceMethod 的结果
// 去下手：它返回的是继承来的方法，会给一个本来没实现该方法的类平白加上一个方法，
// 拿到的原 IMP 也不是那一层自己的。所以要逐层比对实现指针，只挑"和父类不同"的层。
//
// 登记表满了就先别挂：挂了却没记下原 IMP 的话，vcamLookupOrig 找不到，回调只能空转，
// 那一帧的真实数据就白丢了。
static BOOL vcamHookClass(Class cls, SEL sel, IMP hook) {
    if (!cls) return NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        Method m = class_getInstanceMethod(c, sel);
        if (!m) return NO;
        Method up = class_getInstanceMethod(class_getSuperclass(c), sel);
        if (!up || method_getImplementation(m) != method_getImplementation(up)) {
            if (vcamIsHookedFor(c, sel)) return YES;
            if (g_hookCount >= VCAM_MAX_HOOKS) {
                VCamLog(@"hook 登记表已满，%@ 不再挂钩", NSStringFromClass(c));
                return NO;
            }
            IMP orig = NULL;
            MSHookMessageEx(c, sel, hook, &orig);
            return vcamRememberHook(c, sel, orig);
        }
    }
    return NO;
}

static BOOL vcamHookImplementation(id obj, SEL sel, IMP hook) {
    if (!obj) return NO;
    return vcamHookClass(object_getClass(obj), sel, hook);
}

// 把录下来的文件换成我们的视频。重复调用无害，失败只记日志不抛，绝不能影响录像本身。
//
// 顺序上有个坑：原来是"先把原文件删了，再拷我们的"。拷贝只要失败（源读不到、目录一时
// 不可用、空间不足），用户刚录的那段就**彻底没了**，而且连替代品也没有。改成先拷到
// 同目录的临时文件（同卷改名是原子操作）、拷成功才顶掉原文件 —— 拷贝失败时原文件原封不动。
static void vcamReplaceRecordedFile(NSURL *url) {
    if (!g_vcamEnabled || g_playingPath.length == 0 || url.path.length == 0) return;
    if ([g_playingPath isEqualToString:url.path]) return;      // 源和目标同一个就别折腾

    NSError *err = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [url.path stringByAppendingString:@".vcam.tmp"];
    [fm removeItemAtPath:tmp error:NULL];

    if (![fm copyItemAtPath:g_playingPath toPath:tmp error:&err]) {
        VCamLog(@"录像替换失败（原文件保持不动）：%@", err.localizedDescription);
        return;
    }
    [fm removeItemAtPath:url.path error:NULL];
    if ([fm moveItemAtPath:tmp toPath:url.path error:&err]) {
        VCamLog(@"录像替换生效：%@ <- %@", url.path, g_playingPath);
    } else {
        // 同目录改名几乎不会失败；真失败了也别留垃圾，把临时文件挪回原位当替代品
        VCamLog(@"录像替换收尾失败：%@", err.localizedDescription);
        [fm moveItemAtPath:tmp toPath:url.path error:NULL];
    }
}

// 代理的 didFinishRecording 回调 —— 此时文件已定型，是替换的安全时机。
// 第三个参数名是复数 fromConnections:，类型是 NSArray（是**组**连接，不是单个连接）——
// 别跟 AVCaptureVideoDataOutput 那条单数的 fromConnection: 混了，上一版就是写成单数，
// class_getInstanceMethod 找不到方法返回 nil，于是"没实现 didFinishRecording，跳过 hook"，
// 这条替换路径静默地一次都没装上。
static void vcamDidFinishRecording(id self, SEL _cmd, AVCaptureFileOutput *output,
                                   NSURL *outputFileURL, NSArray *connections,
                                   NSError *error) {
    vcamReplaceRecordedFile(outputFileURL);

    IMP orig = vcamLookupOrig(self, _cmd);
    if (orig) {
        ((void (*)(id, SEL, AVCaptureFileOutput *, NSURL *, NSArray *, NSError *))orig)(
            self, _cmd, output, outputFileURL, connections, error);
    }
}

// 给录像代理装上回调 hook，按实际对象的类动态安装。
static void vcamInstallRecordHook(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:);
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
        // 记上播放器的当前状态：切换模式（拍照<->录像）后如果这里是新建的覆盖，
        // 日志里就能看出"覆盖在、但播放器已经停了"还是"覆盖压根没建出来"
        VCamLog(@"已挂上预览层覆盖 layer=%p bounds=%@ 播放器=%p rate=%.1f",
                layer, NSStringFromCGRect(layer.bounds), g_maskPlayer,
                g_maskPlayer ? g_maskPlayer.rate : 0.0f);
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

// 播放器代数。每次重建/拆除都加一，用来作废还在路上的那次"拷贝副本" ——
// 拷贝在后台线程做，回来时可能开关已经关了、视频已经换了。
static int g_playGen = 0;

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

// 卡死看门狗与回零状态。它们都是"同一时刻只有一个播放器"的前提下才成立的单例状态，
// 换播放器/拆播放器时必须一起复位（见 vcamTeardownPlayer）。
static NSTimer *g_watchdog = nil;             // 0.5s 一跳，独立于播放时钟
static BOOL s_rewinding = NO;                 // 回零途中：挡住第二次 seek
static CFAbsoluteTime s_rewindStart = 0;      // 回零起点，用来兜底"seek 回调没回来"
static CFAbsoluteTime s_lastKick = 0;         // 上次补 play 的时间，限流用
static int s_kicks = 0;                       // 补 play 次数，日志按它决定记不记

// 主线程
static void vcamTeardownPlayer(void) {
    g_playGen++;      // 作废还在后台拷副本的那一次
    if (g_watchdog) {
        [g_watchdog invalidate];
        g_watchdog = nil;
    }
    s_rewinding = NO;
    s_rewindStart = 0;
    s_lastKick = 0;
    if (g_maskPlayer) {
        // 顺序要紧：观察者的 block 持有播放器，不先摘掉就放不掉
        if (g_timeObserver) {
            [g_maskPlayer removeTimeObserver:g_timeObserver];
            g_timeObserver = nil;
        }
        [g_maskPlayer pause];
        [g_maskPlayer replaceCurrentItemWithPlayerItem:nil];
        g_maskPlayer = nil;
    }
    if (g_timeObserver) {
        g_timeObserver = nil;
    }
    if (g_endObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:g_endObserver];
        g_endObserver = nil;
    }
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

// 回零重播。放在"还差一点点到结尾"时触发，而不是等 didPlayToEnd 通知：
// 通知依赖 item 真的走到结尾才发，而且此时播放器已经停了，重新 play 的时序容易丢
// （上一版就是这么变成"播完就停"的）。定时观察者只要在播就会一直回调，更早也更稳。
//
// 两处是针对用户报的"动态但经常卡住"改的：
//   1) 零容差的 seek 是"精确到帧"，要从前面一个关键帧重新解，慢到肉眼可见。而观察者
//      每 0.25s 就回调一次，每次看位置还在结尾就再排一次 seek —— 几次精确 seek 叠在
//      一起，画面就一直定在最后一帧，看着就是卡住。现在给 1/15 秒容差（落到就近关键帧，
//      快得多），并且同一时刻只允许一次 seek 在飞。
//   2) 加一把看门狗（下面 vcamPlayerWatchdog），兜住"播放器被暂停且自己不会醒"的情况。
static void vcamRewindAndPlay(AVPlayer *p) {
    if (!p || p != g_maskPlayer || s_rewinding) return;
    s_rewinding = YES;
    s_rewindStart = CFAbsoluteTimeGetCurrent();
    CMTime tol = CMTimeMake(1, 15);
    [p seekToTime:kCMTimeZero
        toleranceBefore:tol
         toleranceAfter:tol
      completionHandler:^(BOOL finished) {
        // 回调的线程不保证，动播放器一律回主线程
        dispatch_async(dispatch_get_main_queue(), ^{
            s_rewinding = NO;
            s_lastKick = CFAbsoluteTimeGetCurrent();   // 刚回零，别马上又补 play
            if (finished && p == g_maskPlayer) [p play];
        });
    }];
}

// 看门狗：每 0.5s 跳一次，判断"该播但没在播"。
//
// 为什么不能只靠时间观察者（addPeriodicTimeObserverForInterval:）：它只在播放真的推进
// 时周期性回调，播放器一停就只剩最后一次回调 —— 正好是它停住的那一刻，之后再也不跳，
// 于是"卡住"这件事没人发现。所以用一个跟播放时钟无关的 NSTimer。
//
// 已知的、也是用户看到的"录像模式下画面静止"最可能的原因：资源里有音轨时，
// AVPlayer 会去用 AVAudioSession，而相机一进录像模式就把会话切成 PlayAndRecord，
// 播放器于是被判为"被别的会话打断"而自动暂停 —— 自己不会恢复。这里做两件事：
// 顶层把音轨从播放器项里去掉（vcamMakeVideoOnlyItem），看门狗当第二道保险。
// 日志里每补一次 play 都留痕，下一轮就能从日志看出到底有没有被打断。
static void vcamPlayerWatchdog(void) {
    AVPlayer *p = g_maskPlayer;
    if (!p) return;
    AVPlayerItem *ci = p.currentItem;
    if (!ci || ci.status != AVPlayerItemStatusReadyToPlay) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    // seek 回调要是没回来（被拆播放器/异常），别把 s_rewinding 永久卡住
    if (s_rewinding) {
        if (now - s_rewindStart > 2.0) {
            VCamLog(@"回零 seek 超过 2 秒没回调，强制解锁");
            s_rewinding = NO;
        }
        return;
    }

    if (p.rate > 0) return;      // 正在播，什么都不用做
    // 1 = 在等缓冲/等别的条件（WaitingToPlayAtSpecifiedRate），它自己会继续，插一脚反而打乱。
    // 这里不写枚举名而写数值：那个枚举在 SDK 里改过名，踩上废弃标注就是 -Werror 卡构建，
    // 而数值是稳定的 ABI，日志里也会把原始数值打出来。
    if (p.timeControlStatus == 1) return;

    CMTime dur = ci.duration;
    CMTime cur = p.currentTime;
    if (CMTIME_IS_VALID(dur) && CMTimeGetSeconds(dur) > 0.4 &&
        CMTimeGetSeconds(CMTimeSubtract(dur, cur)) < 0.35) {
        vcamRewindAndPlay(p);    // 停在结尾：该回零而不是 play
        return;
    }

    if (now - s_lastKick < 1.0) return;    // 限流：最多每秒补一次
    s_lastKick = now;
    s_kicks++;
    if (s_kicks <= 5 || s_kicks % 20 == 0) {
        VCamLog(@"画面定格：rate=0 状态=%ld 位置=%.2f/%.2f，第 %d 次补 play",
                (long)p.timeControlStatus, CMTimeGetSeconds(cur),
                CMTimeGetSeconds(dur), s_kicks);
    }
    [p play];
}

// 造一个"只有视频轨"的播放器项。
//
// 为什么不能直接把 URL 交给 AVPlayer：资源里有音轨时 AVPlayer 就会碰 AVAudioSession，
// 而相机进录像模式会把会话切成 PlayAndRecord，播放器被判为"被打断"就停在原地不动
// （屏幕上正是用户看到的"录像模式画面静止"；拍照模式不动音频会话，所以那边一直能动）。
// 把音轨从播放器项里摘掉，播放器就不会再去动音频会话。
//
// 读轨道必须用 iOS15+ 的异步接口：同步的 tracksWithMediaType: 在 17.5 SDK 里已废弃，
// 开着 -Werror 会直接卡构建。它在别的线程回调，所以这里只组装，起播放器要回主线程。
// 任何一步不成就退回"按原文件播"，绝不因为这一步做不成而没有画面。
static void vcamMakeVideoOnlyItem(NSURL *url, void (^done)(AVPlayerItem *item, NSString *note)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack *> * _Nullable tracks,
                                     NSError * _Nullable error) {
        AVPlayerItem *item = nil;
        NSString *note = nil;
        AVAssetTrack *vt = tracks.firstObject;
        AVMutableComposition *comp = nil;

        if (vt) {
            comp = [AVMutableComposition composition];
            AVMutableCompositionTrack *ct =
                [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                                preferredTrackID:kCMPersistentTrackID_Invalid];
            NSError *e = nil;
            // 时长取轨道自己的 timeRange（不用 AVAsset.duration，那个在 17.5 里已废弃）
            if (ct && [ct insertTimeRange:CMTimeRangeMake(kCMTimeZero, vt.timeRange.duration)
                                  ofTrack:vt atTime:kCMTimeZero error:&e]) {
                // 构图轨道不会自动继承原轨道的方向信息（竖屏视频常靠 preferredTransform
                // 摆正）。漏了这行，本来竖着拍的视频会被摆横。
                // 用 KVC 取这个结构体属性：万一它在 17.5 SDK 里被标了废弃，直接写属性名
                // 就会卡构建，而 KVC 取不到只是少一次摆正，不会崩。
                id tf = vcamValueIfResponds(vt, @selector(preferredTransform));
                if ([tf isKindOfClass:[NSValue class]]) {
                    ct.preferredTransform = [(NSValue *)tf CGAffineTransformValue];
                } else {
                    VCamLog(@"取不到原视频的方向信息，按不旋转播放");
                }
                item = [AVPlayerItem playerItemWithAsset:comp];
                note = @"已剥掉音轨（不让播放器碰音频会话）";
            } else {
                note = [NSString stringWithFormat:@"音轨剥离失败（%@），按原文件播",
                        e.localizedDescription ?: @"?"];
            }
        } else {
            note = [NSString stringWithFormat:@"没读到视频轨（%@），按原文件播",
                    error.localizedDescription ?: @"?"];
        }

        if (!item) item = [AVPlayerItem playerItemWithURL:url];
        dispatch_async(dispatch_get_main_queue(), ^{ done(item, note); });
    }];
}

static void vcamStartPlayerAttempt(NSString *sharedPath, NSString *playPath, int attempt);
static void vcamBeginPlayback(NSString *sharedPath, NSString *playPath, int attempt,
                              AVPlayerItem *item, NSString *note);

// 先拷一份到本进程自己的容器里再播。AVPlayer 的解码在进程外做（mediaserverd），
// 共享目录 /var/tmp/VCam 那种位置它未必有权限 —— 症状正好是我们踩到的：播放器
// rate=1.0 却 currentTime 永远是 0、画面定格，而同一个文件交给本进程内的
// AVAssetImageGenerator 取帧却完全正常。放自己容器里就没这问题。
// 拷贝放后台：用户选的视频可能几十上百 MB，在主线程上拷会卡住界面，
// 相机进程卡久了还会被看门狗杀掉。
//
// 注意 g_playingPath 始终记"共享目录里那个原始路径"（取帧生成器和共享状态比对
// 都按它来），播放器实际播的是副本 —— 两者不能混，混了就会每帧布局都重启一次播放器。
static void vcamStartPlayer(NSString *sharedPath) {
    if (sharedPath.length == 0) return;

    g_playGen++;
    int gen = g_playGen;
    NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VCamPlay.mov"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *playPath = sharedPath;
        NSError *err = nil;
        NSFileManager *fm = [NSFileManager defaultManager];
        // copyItemAtPath 目标已存在会直接失败，必须先删（否则第二次起就一直退回共享路径，
        // 定格那个毛病会原样回来）
        [fm removeItemAtPath:dst error:NULL];
        if (![fm copyItemAtPath:sharedPath toPath:dst error:&err]) {
            VCamLog(@"播放副本拷贝失败，直接放原文件：%@", err.localizedDescription);
        } else {
            playPath = dst;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != g_playGen) return;     // 这期间开关关了或换了视频，这次作废
            vcamStartPlayerAttempt(sharedPath, playPath, 0);
        });
    });
}

// 主线程。先拆旧的，再异步造"只有视频轨"的播放器项，项造好了才真正起播放器
// （造项走的是异步接口，这一步不能再按同步流程写）。
static void vcamStartPlayerAttempt(NSString *sharedPath, NSString *playPath, int attempt) {
    vcamTeardownPlayer();
    int gen = g_playGen;      // teardown 会 ++g_playGen，所以这里记的才是"本次"的代号
    vcamMakeVideoOnlyItem([NSURL fileURLWithPath:playPath],
                          ^(AVPlayerItem *item, NSString *note) {
        if (gen != g_playGen) return;    // 等项这会儿开关关了/换了视频，本次作废
        vcamBeginPlayback(sharedPath, playPath, attempt, item, note);
    });
}

// 主线程。注意这个函数的执行时机不再紧跟 vcamStartPlayerAttempt，中间隔着一次异步加载。
static void vcamBeginPlayback(NSString *sharedPath, NSString *playPath, int attempt,
                              AVPlayerItem *item, NSString *note) {
    // 注意是 initWithPlayerItem:（不是 initWithItem:），上一轮 AVQueuePlayer 也是栽在
    // 这类"想当然的初始化方法"上。这里用 alloc/init 而不是 +playerWithPlayerItem:，
    // 少绕一层类方法查找
    AVPlayer *p = [[AVPlayer alloc] initWithPlayerItem:item];
    // 不用 AVQueuePlayer + AVPlayerLooper：实测这台设备上 looper 的两个版本
    // （空队列版、把模板塞进队列版）时钟都不走，画面定在第一帧 —— 铁证是三张
    // "假照片"字节数完全相同，说明每次取到的都是同一帧。循环自己做。
    p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    p.muted = YES;      // 假画面不该出声；音轨在造项时已经剥掉了
    VCamLog(@"播放器项：%@", note ?: @"(无说明)");

    g_maskPlayer = p;
    g_playingPath = [sharedPath copy];
    g_playerTicks = 0;
    s_kicks = 0;

    __weak AVPlayer *wp = p;
    g_timeObserver = [p addPeriodicTimeObserverForInterval:CMTimeMake(1, 4)
                                                     queue:dispatch_get_main_queue()
                                                usingBlock:^(CMTime t) {
        AVPlayer *sp = wp;
        if (!sp || sp != g_maskPlayer) return;
        g_playerTicks++;        // 时钟在走 = 画面在动
        CMTime dur = sp.currentItem.duration;
        if (CMTIME_IS_VALID(dur) && CMTimeGetSeconds(dur) > 0.4 &&
            CMTimeGetSeconds(CMTimeSubtract(dur, t)) < 0.35) {
            vcamRewindAndPlay(sp);
        }
    }];
    g_endObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { (void)n; vcamRewindAndPlay(wp); }];

    // 看门狗跟播放器同生共死（拆播放器时 invalidate），0.5s 一跳
    if (g_watchdog) {
        [g_watchdog invalidate];
        g_watchdog = nil;
    }
    g_watchdog = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                 repeats:YES
                                                   block:^(NSTimer *t) { vcamPlayerWatchdog(); }];

    [p play];

    // 起播 3 秒后体检。定格这种毛病光看"开始播放"那行分不出来：得知道时钟走没走、
    // item 到底 ready 没有、播放器是不是卡在等待上、有没有报错。时钟一拍没走就重建。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_maskPlayer != p) return;      // 这期间被换掉或关掉了

        AVPlayerItem *ci = p.currentItem;
        VCamLog(@"播放器体检：时钟=%d 拍 补play=%d 次 item.status=%ld 时长=%.2f 位置=%.2f 播放状态=%ld 等待原因=%@ 错误=%@",
                g_playerTicks, s_kicks, (long)ci.status,
                CMTimeGetSeconds(ci.duration), CMTimeGetSeconds(p.currentTime),
                (long)p.timeControlStatus,
                p.reasonForWaitingToPlay ?: @"-",
                ci.error.localizedDescription ?: @"-");

        if (g_playerTicks == 0 && attempt < 2) {
            VCamLog(@"播放器时钟没动，第 %d 次重建", attempt + 1);
            vcamStartPlayerAttempt(sharedPath, playPath, attempt + 1);
        }
    });

    VCamLog(@"开始播放 %@（第 %d 次尝试，本进程已登记预览层 %lu 个）",
            playPath, attempt, (unsigned long)g_previewLayers.count);
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

// 生成器不是线程安全的，而取帧会从两条队列同时来：App 的采集队列（采集代理 hook）
// 和 App 的写入队列（AVAssetWriter hook）。两个线程同时 copyCGImageAtTime: 会出乱子，
// 所以串起来 —— 一次解码 5~15ms，互相等一会儿远好过崩。
static NSLock *vcamGeneratorLock(void) {
    static NSLock *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [[NSLock alloc] init]; });
    return l;
}

static AVAssetImageGenerator *vcamImageGenerator(void) {
    NSLock *lock = vcamGeneratorLock();
    [lock lock];
    if (!g_imageGen || ![g_imageGenPath isEqualToString:g_playingPath]) {
        g_imageGen = vcamMakeGenerator(0);
        g_imageGenPath = g_playingPath ? [g_playingPath copy] : nil;
    }
    AVAssetImageGenerator *gen = g_imageGen;
    [lock unlock];
    return gen;
}

// 采集路径每帧都要取一次图，解码成本必须压住：限到 960x540（假画面够看了）
// 并允许 ±1/15 秒的取帧误差，这样生成器能就近取帧而不必精确解码每一帧。
static AVAssetImageGenerator *vcamBufferImageGenerator(void) {
    NSLock *lock = vcamGeneratorLock();
    [lock lock];
    if (!g_bufGen || ![g_bufGenPath isEqualToString:g_playingPath]) {
        g_bufGen = vcamMakeGenerator(960);
        if (g_bufGen) {
            g_bufGen.requestedTimeToleranceBefore = CMTimeMake(1, 15);
            g_bufGen.requestedTimeToleranceAfter = CMTimeMake(1, 15);
        }
        g_bufGenPath = g_playingPath ? [g_playingPath copy] : nil;
    }
    AVAssetImageGenerator *gen = g_bufGen;
    [lock unlock];
    return gen;
}

// 取指定生成器在播放头位置的帧。+1 的 CGImage，调用方负责 CGImageRelease
static CGImageRef vcamCopyFrameFrom(AVAssetImageGenerator *gen) {
    if (!gen) return NULL;

    CMTime t = g_maskPlayer ? g_maskPlayer.currentTime : kCMTimeZero;
    NSLock *lock = vcamGeneratorLock();
    [lock lock];
    CGImageRef img = [gen copyCGImageAtTime:t actualTime:NULL error:NULL];
    // 播放头正好卡在结尾时会取不到，退回第一帧，总比让 App 拿到真图好
    if (!img) img = [gen copyCGImageAtTime:kCMTimeZero actualTime:NULL error:NULL];
    [lock unlock];
    return img;
}

static CGImageRef vcamCopyCurrentFrameImage(void) {
    return vcamCopyFrameFrom(vcamImageGenerator());
}

// CGImage -> 指定格式的字节。不走 UIImage（相关的便捷方法在这个 SDK 里不齐），
// 直接用 ImageIO。UTI 写死字符串而不引 kUTTypeJPEG/kUTTypeHEIC：后者已废弃，
// 而本项目开了 -Werror，一个弃用警告就能让构建失败。
static NSData *vcamEncodeImage(CGImageRef img, CFStringRef uti, CGFloat quality) {
    NSMutableData *out = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)out, uti, 1, NULL);
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

    // App 要什么格式就给什么格式。实测系统相机取的是 public.heic，而之前我们一律塞
    // JPEG 字节 —— 文件按 .HEIC 存下来、内容却是 JPEG，相册很可能直接不认这张图。
    BOOL wantHEIC = [g_requestedPhotoType.lowercaseString containsString:@"heic"];
    NSData *data = nil;
    if (wantHEIC) data = vcamEncodeImage(img, CFSTR("public.heic"), 0.9);
    BOOL usedHEIC = (data != nil);
    if (!data) data = vcamEncodeImage(img, CFSTR("public.jpeg"), 0.92);
    CGImageRelease(img);

    if (data) {
        static NSString *loggedType = nil;
        if (![loggedType isEqualToString:usedHEIC ? @"heic" : @"jpeg"]) {
            loggedType = usedHEIC ? @"heic" : @"jpeg";
            VCamLog(@"拍照替换生效：已返回假 %@ %lu 字节（App 要的是 %@）",
                    usedHEIC ? @"HEIC" : @"JPEG", (unsigned long)data.length,
                    g_requestedPhotoType ?: @"未记录");
        }
    }
    return data;
}

#pragma mark 像素缓冲工具

static CVPixelBufferRef vcamCreatePixelBuffer(size_t w, size_t h, OSType pf) {
    // IOSurface 是编码器/写入器要的（不是 IOSurface 背书的缓冲它们可能直接拒收）。
    // 另外两个只在 BGRA 上才有意义 —— 420 是双平面，给平面格式带上 bitmap 兼容标记
    // 可能让 CVPixelBufferCreate 直接失败，而那条路只有真机跑起来才知道。
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    attrs[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
    if (pf == kCVPixelFormatType_32BGRA) {
        attrs[(id)kCVPixelBufferCGImageCompatibilityKey] = @YES;
        attrs[(id)kCVPixelBufferCGBitmapContextCompatibilityKey] = @YES;
    }
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

// 420 的转换得先画到一块 BGRA 上再转。1080p 每帧新建一块 8MB 太浪费，按尺寸缓存一块
// 来回用；两条注入路径（采集代理 / 写入器）可能同时走到这儿，所以拿锁串起来 ——
// 顺带也保证同一帧不会被两处同时转换，A10 就两个核，并行反而更慢。
static NSLock *vcamFillLock(void) {
    static NSLock *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [[NSLock alloc] init]; });
    return l;
}

// 把假帧画进给定的像素缓冲（原地）。BGRA 直接画；420 要先画到 BGRA 再转。
// 写入器那条路不能换缓冲（适配器的池、App 还拿着引用），只能原地填。
static BOOL vcamFillPixelBuffer(CVPixelBufferRef pb, CGImageRef img) {
    if (!pb || !img) return NO;
    OSType pf = CVPixelBufferGetPixelFormatType(pb);
    if (pf == kCVPixelFormatType_32BGRA) return vcamDrawIntoBGRAPixelBuffer(pb, img);

    if (pf != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        pf != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return NO;

    size_t w = CVPixelBufferGetWidth(pb);
    size_t h = CVPixelBufferGetHeight(pb);
    NSLock *lock = vcamFillLock();
    [lock lock];
    static CVPixelBufferRef s_scratch = NULL;
    static size_t s_sw = 0, s_sh = 0;
    if (!s_scratch || s_sw != w || s_sh != h) {
        if (s_scratch) CVPixelBufferRelease(s_scratch);
        s_scratch = vcamCreatePixelBuffer(w, h, kCVPixelFormatType_32BGRA);
        s_sw = s_scratch ? w : 0;
        s_sh = s_scratch ? h : 0;
    }
    BOOL ok = NO;
    if (s_scratch && vcamDrawIntoBGRAPixelBuffer(s_scratch, img) &&
        CVPixelBufferLockBaseAddress(s_scratch, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        if (CVPixelBufferLockBaseAddress(pb, 0) == kCVReturnSuccess) {
            vcamConvertBGRAto420(s_scratch, pb,
                                 pf == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            ok = YES;
        }
        CVPixelBufferUnlockBaseAddress(s_scratch, kCVPixelBufferLock_ReadOnly);
    }
    [lock unlock];
    return ok;
}

// 造一块和原帧同尺寸同格式的假帧缓冲。刻意不复用原缓冲：采回来的那块可能同时被
// 预览/分析等其他消费者用着，动它会连带影响它们。
static CVPixelBufferRef vcamCreateFakePixelBufferLike(CVPixelBufferRef origPB) {
    OSType pf = CVPixelBufferGetPixelFormatType(origPB);
    if (pf != kCVPixelFormatType_32BGRA &&
        pf != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        pf != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        static int loggedPf = 0;
        if (loggedPf != (int)pf) {
            loggedPf = (int)pf;
            VCamLog(@"采集帧格式 %u 暂不支持替换，真实帧放行", (unsigned)pf);
        }
        return NULL;
    }
    return vcamCreatePixelBuffer(CVPixelBufferGetWidth(origPB),
                                 CVPixelBufferGetHeight(origPB), pf);
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

// 给替换出来的帧盖个自己的戳。采集回调和我们给 AVAssetWriterInput 上的兜底 hook
// 会先后看到同一个 buffer，有这个戳就不必把同一帧解码两遍。
#define VCAM_FAKE_KEY CFSTR("VCamFakeFrame")

static BOOL vcamIsFakeSampleBuffer(CMSampleBufferRef sb) {
    if (!sb) return NO;
    // 取 attachments 必须传 false：传 true 会凭空给 buffer 建出一个附件表
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (!arr || CFArrayGetCount(arr) == 0) return NO;
    CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    return CFDictionaryContainsKey(d, VCAM_FAKE_KEY) ? YES : NO;
}

static void vcamMarkFakeSampleBuffer(CMSampleBufferRef sb) {
    CFArrayRef arr = CMSampleBufferGetSampleAttachmentsArray(sb, true);
    if (!arr || CFArrayGetCount(arr) == 0) return;
    CFMutableDictionaryRef d = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(arr, 0);
    CFDictionarySetValue(d, VCAM_FAKE_KEY, kCFBooleanTrue);
}

// 造一个与真实帧同尺寸同格式的假帧，再包成 CMSampleBuffer。
// format description 直接沿用原始的，所以下游（编码器/写入器）看到的仍然是它认识
// 的那个格式，不需要为我们的替换改任何设置。任何一步不对就返回 NULL，调用方原样
// 放行真实帧 —— 插件不能把相机本身搞坏。
// 每帧替换要花多久。1080p30 的预算是 33ms，超了画面就会开始丢帧 —— 这条日志是
// 判断"要不要把取帧尺寸从 960 降下来"的唯一依据，所以每 60 帧打一次。
static void vcamNoteInjectCost(NSTimeInterval ms) {
    static double s_sum = 0;
    static int s_n = 0;
    static double s_max = 0;
    s_sum += ms;
    s_n++;
    if (ms > s_max) s_max = ms;
    if (s_n >= 60) {
        VCamLog(@"注入耗时：平均 %.1fms 峰值 %.1fms（最近 %d 帧）", s_sum / s_n, s_max, s_n);
        s_sum = 0;
        s_n = 0;
        s_max = 0;
    }
}

// 给写入器那条路用：不能换 buffer（适配器的池、App 可能还拿着引用），只能原地填。
static BOOL vcamFillPixelBufferWithCurrentFrame(CVPixelBufferRef pb) {
    if (!pb || !g_vcamEnabled || !g_maskPlayer || g_playingPath.length == 0) return NO;

    CGImageRef img = vcamCopyBufferFrameImage();
    if (!img) return NO;

    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    BOOL ok = vcamFillPixelBuffer(pb, img);
    vcamNoteInjectCost(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
    CGImageRelease(img);
    return ok;
}

static CMSampleBufferRef vcamMakeFakeSampleBuffer(AVCaptureOutput *output, CMSampleBufferRef orig) {
    if (!g_vcamEnabled || !g_maskPlayer || g_playingPath.length == 0) return NULL;
    // output 传 nil 表示调用方是 AVAssetWriterInput 那条兜底路径，来源未知就不挑
    if (output && ![output isKindOfClass:[AVCaptureVideoDataOutput class]]) return NULL;
    if (vcamIsFakeSampleBuffer(orig)) return NULL;     // 已经是假帧了，别再解一遍

    CVImageBufferRef origPB = CMSampleBufferGetImageBuffer(orig);
    if (!origPB) return NULL;      // 音频等没有图像平面的，一律放行

    OSType pf = CVPixelBufferGetPixelFormatType(origPB);
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(orig);
    if (!fmt || !CVPixelBufferGetWidth(origPB) || !CVPixelBufferGetHeight(origPB)) return NULL;

    CMSampleTimingInfo timing;
    if (CMSampleBufferGetSampleTimingInfo(orig, 0, &timing) != noErr) return NULL;

    CVPixelBufferRef pb = vcamCreateFakePixelBufferLike(origPB);
    if (!pb) return NULL;

    CGImageRef img = vcamCopyBufferFrameImage();
    if (!img) {
        CVPixelBufferRelease(pb);
        return NULL;
    }

    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    BOOL filled = vcamFillPixelBuffer(pb, img);
    vcamNoteInjectCost(([NSDate timeIntervalSinceReferenceDate] - t0) * 1000.0);
    CGImageRelease(img);
    if (!filled) {
        CVPixelBufferRelease(pb);
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

    vcamMarkFakeSampleBuffer(out);

    static int loggedPf = 0;
    if (loggedPf != (int)pf) {
        loggedPf = (int)pf;
        VCamLog(@"采集帧注入生效：%lux%lu pf=%u 来源=%@",
                (unsigned long)CVPixelBufferGetWidth(origPB),
                (unsigned long)CVPixelBufferGetHeight(origPB), (unsigned)pf,
                output ? @"采集代理" : @"写入器兜底");
    }
    return out;    // +1，调用方负责 CFRelease
}

// 代理的采集回调。这是我们唯一能改到"真正被写进文件的那份数据"的地方。
static void vcamDidOutputSampleBuffer(id self, SEL _cmd, AVCaptureOutput *output,
                                      CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
    IMP orig = vcamLookupOrig(self, _cmd);
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

// 系统相机的采集代理类名是固定的（实测日志里出现过 CAMCaptureEngine，还是 KVO 子类
// NSKVONotifying_CAMCaptureEngine），但它注册代理这一步不保证经过我们的
// setSampleBufferDelegate hook —— 新构建里那条 hook 一次都没抓到非空代理。所以不等
// 它送上门，直接按类名挂。挂多了也无害：真正的替换条件（开关开着 + 有图像平面）
// 都在 vcamMakeFakeSampleBuffer 里把关，不满足就原样放行。
// 类还没加载时直接跳过，下次（预览层出现时）再试一次。
static void vcamInstallKnownCaptureHooks(void) {
    NSArray *names = @[@"CAMCaptureEngine",
                       @"CAMVideoCaptureEngine",
                       @"CAMStillImageCaptureEngine"];
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    for (NSString *n in names) {
        Class c = NSClassFromString(n);
        if (!c || vcamIsHooked(c)) continue;
        if (!class_getInstanceMethod(c, sel)) {
            VCamLogOnce([@"noDidOutput:" stringByAppendingString:n],
                        [NSString stringWithFormat:@"%@ 没实现 didOutput，跳过", n]);
            continue;
        }
        if (vcamHookClass(c, sel, (IMP)vcamDidOutputSampleBuffer)) {
            VCamLog(@"已按类名给 %@ 装上采集注入 hook", n);
        }
    }
}

#pragma mark 采集拓扑诊断（下一轮靠数据说话）

// 相机那个壳二进制只有 61KB，真正的代码在 CameraKit/CameraUI 里，而那些框架只存在于
// dyld 共享缓存 —— 离线怎么查都查不出它用哪条采集/写入路径。既然如此就让它自己说。
//
// 这一段同时也是"安装 hook 的入口"：不要等 App 调 setSampleBufferDelegate: 送上门
// （新构建里那条 hook 一次都没抓到非空代理），直接拿公开 getter 问它要代理。
static NSHashTable *g_seenOutputs = nil;      // weak：AVCaptureOutput

static void vcamInstallMetadataHook(id delegate);

// 诊断用的取值一律走这里。原因是本项目两个约束叠在一起很要命：SDK 是 17.5、又开着
// -Werror，哪个属性要是被标了废弃就直接卡构建；可要是不写属性改成 KVC，那个属性万一
// 在 SDK 里不存在，运行时就会抛 NSUnknownKeyException 把相机搞崩。
// 所以先 respondsToSelector（@selector 只是名字，编译期不要求属性存在）再 KVC 取值，
// 取不到就返回 nil，日志里显示成 (null) 而已 —— 诊断代码绝不能反过来影响相机。
static id vcamValueIfResponds(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    return [obj valueForKey:NSStringFromSelector(sel)];
}

// 登记 output 用的锁。addOutput: 在主线程、startRunning 在会话自己的队列、
// layoutSublayers 在主线程 —— NSHashTable 不是线程安全的，这几个入口得上同一把锁。
// 它必须是普通 NSLock 且不可重入，所以调用链上要小心别自嵌套
// （vcamRefreshKnownOutputs 就是只取快照、到锁外再逐个喂进来）。
static NSLock *vcamOutputLock(void) {
    static NSLock *l = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = [[NSLock alloc] init]; });
    return l;
}

static void vcamNoteOutput(AVCaptureOutput *output) {
    if (!output) return;

    NSLock *lock = vcamOutputLock();
    [lock lock];

    if (!g_seenOutputs) g_seenOutputs = [NSHashTable weakObjectsHashTable];
    [g_seenOutputs addObject:output];

    if ([output isKindOfClass:[AVCaptureVideoDataOutput class]]) {
        id d = vcamValueIfResponds(output, @selector(sampleBufferDelegate));
        NSString *dn = d ? NSStringFromClass(object_getClass(d)) : @"(nil)";
        VCamLogOnce([NSString stringWithFormat:@"topoV:%p:%@", output, dn],
                    [NSString stringWithFormat:@"拓扑：采集输出 %p 代理=%@ 设置=%@",
                     output, dn, vcamValueIfResponds(output, @selector(videoSettings))]);
        vcamInstallSampleBufferHook(d);          // nil 会被忽略
    } else if ([output isKindOfClass:[AVCaptureMetadataOutput class]]) {
        id d = vcamValueIfResponds(output, @selector(metadataObjectsDelegate));
        NSString *dn = d ? NSStringFromClass(object_getClass(d)) : @"(nil)";
        VCamLogOnce([NSString stringWithFormat:@"topoM:%p:%@", output, dn],
                    [NSString stringWithFormat:@"拓扑：元数据输出 %p 代理=%@ 类型=%@",
                     output, dn, vcamValueIfResponds(output, @selector(metadataObjectTypes))]);
        vcamInstallMetadataHook(d);
    } else {
        VCamLogOnce([NSString stringWithFormat:@"topoX:%p", output],
                    [NSString stringWithFormat:@"拓扑：其他输出 %p 类型=%@（不处理）",
                     output, NSStringFromClass([output class])]);
    }

    [lock unlock];
}

// 把见过的 output 再问一遍。代理有可能设得比 addOutput 晚，所以 startRunning 和
// 预览层布局时都来补问一次（日志按"输出 + 代理类"去重，不会刷屏）。
static void vcamRefreshKnownOutputs(void) {
    NSArray *snapshot = nil;
    NSLock *lock = vcamOutputLock();
    [lock lock];                                // 只在锁里取快照，真正的工作在锁外做
    snapshot = g_seenOutputs.allObjects;
    [lock unlock];

    for (AVCaptureOutput *o in snapshot) vcamNoteOutput(o);
}

#pragma mark 元数据屏蔽（扫码/人脸）

// 用户要的是"相机识别不出真实画面"。识别流水线在 AVFoundation 内部，喂不进假帧
// （元数据是检测结果的描述，不是像素），能做的是让结果不出现在 App 面前。
// 代价：真人脸也不会出黄框了 —— 这正是要的效果。
static void vcamDidOutputMetadataObjects(id self, SEL _cmd, AVCaptureOutput *output,
                                         NSArray *metadataObjects, AVCaptureConnection *connection) {
    IMP orig = vcamLookupOrig(self, _cmd);
    if (!orig) return;

    NSArray *pass = metadataObjects;
    if (g_vcamEnabled && g_playingPath.length > 0) {
        VCamLogOnce(@"meta:suppress", @"元数据层命中：已屏蔽识别结果（扫码/人脸/条码）");
        pass = @[];
    }
    ((void (*)(id, SEL, AVCaptureOutput *, NSArray *, AVCaptureConnection *))orig)(
        self, _cmd, output, pass, connection);
}

static void vcamInstallMetadataHook(id delegate) {
    if (!delegate) return;
    SEL sel = @selector(captureOutput:didOutputMetadataObjects:fromConnection:);
    if (![delegate respondsToSelector:sel]) return;
    if (vcamHookImplementation(delegate, sel, (IMP)vcamDidOutputMetadataObjects)) {
        VCamLog(@"已给元数据代理 %@ 装上屏蔽 hook", NSStringFromClass(object_getClass(delegate)));
    }
}

#pragma mark 实况照片的视频部分（采集层够不到，只能事后换文件）

// 实况照片是"同编号的 HEIC + MOV"一对。实测 IMG_0024.HEIC 已经是我们的假帧，但
// IMG_0024.MOV 还是真画面 —— 这段 MOV 由 AVCapturePhotoOutput 内部的实况照片流水线
// 按 settings.livePhotoMovieFileURL 自己写出来，既不经过 App 的采集代理，也不经过
// App 的 AVAssetWriter，采集层和写入层都碰不到它。
// 唯一够得着的缝是"等文件写完，把内容换掉"，跟录像替换一个思路。
static NSURL *g_livePhotoMovieURL = nil;
static BOOL g_livePhotoReplaced = NO;

// 写入方还在写的时候覆盖会把文件毁掉，所以先隔 0.6s 看尺寸稳不稳，稳了才换。
// 连着几次都不稳就放弃：宁可留着真画面，也不能把相册里的文件写坏。
static void vcamReplaceLivePhotoMovieSettled(int attempt) {
    NSURL *url = g_livePhotoMovieURL;
    if (!url.path || g_livePhotoReplaced) return;      // 没有实况照片 / 已经换过了

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        if (attempt < 3) {      // 文件可能还没建出来
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                vcamReplaceLivePhotoMovieSettled(attempt + 1);
            });
        } else {
            VCamLog(@"实况照片 MOV 一直没出现，不替换：%@", url.path);
        }
        return;
    }

    unsigned long long sz1 = [[fm attributesOfItemAtPath:url.path error:NULL] fileSize];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSURL *u = g_livePhotoMovieURL;
        if (!u.path || g_livePhotoReplaced) return;
        unsigned long long sz2 = [[[NSFileManager defaultManager]
                                   attributesOfItemAtPath:u.path error:NULL] fileSize];
        if (sz2 > 0 && sz1 == sz2) {
            g_livePhotoReplaced = YES;
            g_livePhotoMovieURL = nil;
            vcamReplaceRecordedFile(u);
            return;
        }
        if (attempt < 3) {
            VCamLog(@"实况照片 MOV 还在写（%llu -> %llu），稍后再试", sz1, sz2);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                vcamReplaceLivePhotoMovieSettled(attempt + 1);
            });
        } else {
            VCamLog(@"实况照片 MOV 一直没定型，放弃替换（%llu -> %llu）", sz1, sz2);
        }
    });
}

static void vcamDidFinishLivePhotoProcessing(id self, SEL _cmd, AVCapturePhotoOutput *output,
                                             NSURL *outputFileURL, CMTime duration,
                                             CMTime photoDisplayTime,
                                             AVCaptureResolvedPhotoSettings *settings,
                                             NSError *error) {
    if (outputFileURL.path.length) {
        g_livePhotoMovieURL = [outputFileURL copy];
        VCamLog(@"实况照片 MOV 处理完成：%@", outputFileURL.path);
    }
    vcamReplaceLivePhotoMovieSettled(0);

    IMP orig = vcamLookupOrig(self, _cmd);
    if (orig) {
        ((void (*)(id, SEL, AVCapturePhotoOutput *, NSURL *, CMTime, CMTime,
                   AVCaptureResolvedPhotoSettings *, NSError *))orig)(
            self, _cmd, output, outputFileURL, duration, photoDisplayTime, settings, error);
    }
}

static void vcamDidFinishCapture(id self, SEL _cmd, AVCapturePhotoOutput *output,
                                 AVCaptureResolvedPhotoSettings *settings, NSError *error) {
    // 兜底：代理没实现"实况照片处理完成"那个回调时，用拍照收尾这一个
    if (g_livePhotoMovieURL) vcamReplaceLivePhotoMovieSettled(0);

    IMP orig = vcamLookupOrig(self, _cmd);
    if (orig) {
        ((void (*)(id, SEL, AVCapturePhotoOutput *, AVCaptureResolvedPhotoSettings *, NSError *))orig)(
            self, _cmd, output, settings, error);
    }
}

static void vcamInstallPhotoDelegateHooks(id delegate) {
    if (!delegate) return;
    // 优先挂"实况照片 MOV 处理完成"这个精确回调；没有就挂拍照收尾那个兜底
    SEL live = @selector(captureOutput:didFinishProcessingLivePhotoToMovieFileAtURL:duration:photoDisplayTime:resolvedSettings:error:);
    SEL done = @selector(captureOutput:didFinishCaptureForResolvedSettings:error:);
    if ([delegate respondsToSelector:live]) {
        if (vcamHookImplementation(delegate, live, (IMP)vcamDidFinishLivePhotoProcessing)) {
            VCamLog(@"已给拍照代理 %@ 装上实况照片收尾 hook",
                    NSStringFromClass(object_getClass(delegate)));
        }
    } else if ([delegate respondsToSelector:done]) {
        if (vcamHookImplementation(delegate, done, (IMP)vcamDidFinishCapture)) {
            VCamLog(@"已给拍照代理 %@ 装上拍照收尾 hook（它没有实况照片那个回调）",
                    NSStringFromClass(object_getClass(delegate)));
        }
    }
}

#pragma mark 录像（AVCaptureMovieFileOutput）按类挂钩

// 原来只 %hook 了基类 AVCaptureFileOutput，指望"子类继承这个 override"。这条路不成立：
// 方法派发看的是实际类，只要 AVCaptureMovieFileOutput 自己实现了这两个方法
// （它当然实现了），调用就绕过基类，我们的 hook 一次都不会触发 ——
// 日志里 startRecording 从头到尾没出现过，很可能就是这么来的，而不是"相机不用它"。
// 改成按类名各自挂，两个类都挂上，谁实现就命中谁。
//
// 参数个数务必按真实方法写：`-startRecordingToOutputFileURL:recordingDelegate:`
// 只有 (URL, delegate) 两个参数。这里曾经多写了一个 AVCaptureFileOutput*（把它当成
// 代理回调那条三参数的形状了），结果 URL 被当成 output、delegate 被当成 URL、
// 真正的 delegate 拿到的是寄存器里的垃圾值 —— 相机一开始录像就 SIGBUS，
// 崩溃栈停在 objc_retain，地址 0x1。
static void vcamDidStartRecording(id self, SEL _cmd, NSURL *outputFileURL,
                                  id<AVCaptureFileOutputRecordingDelegate> delegate) {
    g_recordingURL = outputFileURL;
    VCamLog(@"开始录像 -> %@（%@）", outputFileURL.path,
            NSStringFromClass(object_getClass(self)));
    vcamInstallRecordHook(delegate);

    IMP orig = vcamLookupOrig(self, _cmd);
    if (orig) {
        ((void (*)(id, SEL, NSURL *, id))orig)(self, _cmd, outputFileURL, delegate);
    }
}

static void vcamDidStopRecording(id self, SEL _cmd) {
    IMP orig = vcamLookupOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL))orig)(self, _cmd);

    // 兜底：万一代理回调没装上，等文件定型后再补一次替换。重复替换无害。
    NSURL *target = g_recordingURL;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        vcamReplaceRecordedFile(target);
    });
}

static void vcamInstallRecordingHooks(void) {
    SEL start = @selector(startRecordingToOutputFileURL:recordingDelegate:);
    SEL stop = @selector(stopRecording);
    for (NSString *n in @[@"AVCaptureMovieFileOutput", @"AVCaptureFileOutput"]) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        if (!vcamIsHookedFor(c, start) && vcamHookClass(c, start, (IMP)vcamDidStartRecording)) {
            VCamLog(@"已给 %@ 装上 startRecording hook", n);
        }
        if (!vcamIsHookedFor(c, stop) && vcamHookClass(c, stop, (IMP)vcamDidStopRecording)) {
            VCamLog(@"已给 %@ 装上 stopRecording hook", n);
        }
    }
}

#pragma mark 写入端诊断

// "实况照片/录像里写的是不是真画面"最后都归到一个问题：App 用哪条路写文件。
// 把 writer 的建立和每个输入的设置记下来，下一轮就不用猜了。
static void vcamNoteWriterStart(AVAssetWriter *w) {
    if (!w) return;
    NSMutableArray *kinds = [NSMutableArray array];
    for (AVAssetWriterInput *inp in w.inputs) {
        [kinds addObject:inp.mediaType ?: @"?"];
    }
    // 注意：AVAssetWriter 公开接口里没有 outputFileURL（只有 outputFileType / inputs），
    // 所以这里不能写属性 —— 上一轮就是这么挂的。目标文件路径对排查很有用，
    // 但只能当"有就记、没有就算了"的可选信息，而且取值必须先判类型再用。
    id outURL = vcamValueIfResponds(w, @selector(outputFileURL));
    NSString *path = [outURL isKindOfClass:[NSURL class]] ? [(NSURL *)outURL path]
                                                          : [outURL description];
    VCamLogOnce([NSString stringWithFormat:@"writer:%@", path ?: @"?"],
                [NSString stringWithFormat:@"写入端：AVAssetWriter 开始写 %@ 容器=%@ 输入=%@",
                 path ?: @"(未知)", w.outputFileType, kinds]);
}

static void vcamNoteWriterInput(id input, AVMediaType mediaType, NSDictionary *outputSettings,
                                NSDictionary *sourcePixelBufferAttributes) {
    if (!input) return;
    VCamLogOnce([NSString stringWithFormat:@"win:%p", input],
                [NSString stringWithFormat:@"写入端：输入 %@ 设置=%@ 源缓冲属性=%@",
                 mediaType, outputSettings, sourcePixelBufferAttributes]);
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
    // 代理类由 App 决定（系统相机是 CAMCaptureEngine），事先不可知，只能拿到对象后
    // 按实际类装 hook。这里只是"顺路"——主力是 vcamNoteOutput 主动去问。
    vcamNoteOutput(self);
}
%end

%hook AVCaptureMetadataOutput
- (void)setMetadataObjectsDelegate:(id<AVCaptureMetadataOutputObjectsDelegate>)objectsDelegate queue:(dispatch_queue_t)objectsQueue {
    %orig;
    vcamNoteOutput(self);
}
%end

%hook AVCaptureSession
- (void)addOutput:(AVCaptureOutput *)output {
    %orig;
    vcamNoteOutput(output);      // output 一到手就记下，代理类随后才知道也没关系
}
- (void)startRunning {
    %orig;
    // 到这里 App 通常已经把代理装好了（也可能没有）。再问一遍，谁有代理就装谁。
    vcamRefreshKnownOutputs();
}
- (void)stopRunning { %orig; }
%end

// 兜底（写入层）：不管 App 用哪个采集代理、甚至把采集代理类名换掉，它用
// AVAssetWriter 写文件时都得经过这两条 append。在这里再换一次，覆盖"代理类名猜不到"。
// 已经是假帧的会被戳记拦下，不会重复解码。
%hook AVAssetWriterInput
- (id)initWithMediaType:(AVMediaType)mediaType outputSettings:(NSDictionary *)outputSettings sourcePixelBufferAttributes:(NSDictionary *)sourcePixelBufferAttributes {
    id r = %orig;
    vcamNoteWriterInput(r, mediaType, outputSettings, sourcePixelBufferAttributes);
    return r;
}
- (BOOL)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CMSampleBufferRef fake = vcamMakeFakeSampleBuffer(nil, sampleBuffer);
    if (fake) VCamLogOnce(@"writer:input", @"写入端命中：AVAssetWriterInput（造新帧替换）");
    BOOL ok = %orig(fake ? fake : sampleBuffer);
    if (fake) CFRelease(fake);
    return ok;
}
%end

// 另一条写入路径：适配器可能自己把像素缓冲包成 sample buffer 再 append，
// 那就绕过了上面那条 hook。这里只能原地改（缓冲是适配器的池，不能换掉）。
%hook AVAssetWriterInputPixelBufferAdaptor
- (BOOL)appendPixelBuffer:(CVPixelBufferRef)pixelBuffer withPresentationTime:(CMTime)presentationTime {
    if (vcamFillPixelBufferWithCurrentFrame(pixelBuffer)) {
        VCamLogOnce(@"writer:adaptor", @"写入端命中：像素缓冲适配器（已原地换帧）");
    }
    return %orig;
}
%end

%hook AVAssetWriter
- (BOOL)startWriting {
    vcamNoteWriterStart(self);
    return %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    // processedFileType 的类型在 SDK 里是 AVFileType（NSString*），但为免记错类型
    // 直接把整数当对象打出来会崩，这里走 KVC 取值 —— 不管它到底是什么都会被装成对象。
    id fileType = [settings valueForKey:@"processedFileType"];
    g_requestedPhotoType = [fileType isKindOfClass:[NSString class]] ? [fileType copy] : nil;

    // 实况照片：把这一对的 MOV 目标路径记下来，等它写完之后换掉（见「实况照片」一节）
    NSURL *movieURL = settings.livePhotoMovieFileURL;
    g_livePhotoMovieURL = movieURL.path.length ? [movieURL copy] : nil;
    g_livePhotoReplaced = NO;

    NSString *key = [NSString stringWithFormat:@"photoDelegate:%@", NSStringFromClass(object_getClass(delegate))];
    VCamLogOnce(key, [NSString stringWithFormat:@"拍照代理 %@ fileType=%@ uniqueID=%lld 实况照片MOV=%@",
                      NSStringFromClass(object_getClass(delegate)),
                      fileType ?: @"(null)",
                      (long long)settings.uniqueID,
                      movieURL.path ?: @"(无)"]);
    vcamInstallPhotoDelegateHooks(delegate);

    %orig;

    // 代理回调都没挂上的兜底：给足时间等文件写完，再按"尺寸稳了才换"的规则替换
    if (movieURL.path.length) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_livePhotoMovieURL) vcamReplaceLivePhotoMovieSettled(3);
        });
    }
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

// 录像替换（AVCaptureMovieFileOutput 那条路）不在 %hook 里做，改用 vcamInstallRecordingHooks
// 按类名挂 —— 原因见那一段的注释：只 hook 基类的话，子类自己实现的同名方法会绕过我们。

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

    // 相机进程这会儿肯定已经起来了，采集/录像相关的类该加载的也都加载了，补挂一遍
    vcamInstallKnownCaptureHooks();
    vcamInstallRecordingHooks();

    // 这一步很关键：相机进程在这里才第一次知道「别的进程已经把虚拟相机打开了」
    vcamApplySharedState();
}
- (void)layoutSublayers {
    %orig;
    // 旋转 / 改尺寸 / 切前后摄会触发；同时也是回到前台后补同步的机会。
    // 代理设得比 addOutput 晚时，靠这里补问出来（日志按"输出+代理类"去重）。
    vcamApplySharedState();
    vcamRefreshKnownOutputs();
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
            vcamInstallKnownCaptureHooks();
            vcamInstallRecordingHooks();
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
