#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
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

#pragma mark 全局变量
static NSMutableArray* g_allVideoDelegates = nil;
static BOOL g_vcamEnabled = NO;
static VCamOverlayWindow *g_overlayWindow = nil;
static UIButton *g_floatButton = nil;
static AVPlayer *g_maskPlayer = nil;
static NSURL *g_selectedVideoUrl = nil;

// 相机预览层注册表。遮罩不再盖整屏，而是贴到每个 AVCaptureVideoPreviewLayer 上：
// 整屏遮罩有两个致命问题 —— 1) 猜不准该盖哪个 window（预览常在别的 window 上，
// 于是「视频在放、预览没变」）；2) 把相机自己的 UI 一起盖住，按钮全点不到。
// 贴在预览层上则天然对齐真实预览区域，且不遮挡 UI。
static NSHashTable *g_previewLayers = nil;    // weak：AVCaptureVideoPreviewLayer
static NSMapTable *g_previewOverlays = nil;   // weak key: 预览层 -> strong value: AVPlayerLayer

static void setupFloatButton(void);
static void handlePanGesture(UIPanGestureRecognizer *gesture);
static void handleTapGesture(UITapGestureRecognizer *gesture);
static void vcamStartOverlay(NSURL *videoUrl);
static void vcamStopOverlay(void);
static void vcamSyncPreviewOverlay(AVCaptureVideoPreviewLayer *layer);

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

// 主线程
static void vcamAttachToAllPreviewLayers(void) {
    for (AVCaptureVideoPreviewLayer *l in g_previewLayers.allObjects) {
        vcamSyncPreviewOverlay(l);
    }
}

// 主线程。先在数组里收好键再改表，避免边遍历边删
static void vcamDetachAllOverlays(void) {
    NSArray *layers = g_previewOverlays.keyEnumerator.allObjects;
    for (AVCaptureVideoPreviewLayer *l in layers) {
        [[g_previewOverlays objectForKey:l] removeFromSuperlayer];
        [g_previewOverlays removeObjectForKey:l];
    }
    if (layers.count) VCamLog(@"已移除 %lu 个预览层覆盖", (unsigned long)layers.count);
}

static void vcamStartOverlay(NSURL *videoUrl) {
    dispatch_async(dispatch_get_main_queue(), ^{
        vcamDetachAllOverlays();
        if (g_maskPlayer) {
            [g_maskPlayer pause];
            g_maskPlayer = nil;
        }

        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:videoUrl];
        g_maskPlayer = [AVPlayer playerWithPlayerItem:item];
        g_maskPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;

        // 播完回到开头接着放，否则视频放到结尾就定格成一张静止画面
        [[NSNotificationCenter defaultCenter]
            addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                        object:item
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            AVPlayer *p = g_maskPlayer;
            if (p && p.currentItem == item) {
                [p seekToTime:kCMTimeZero];
                [p play];
            }
        }];

        [g_maskPlayer play];
        vcamAttachToAllPreviewLayers();
        VCamLog(@"视频已开播：已登记预览层 %lu 个，已挂覆盖 %lu 个",
                (unsigned long)g_previewLayers.count,
                (unsigned long)g_previewOverlays.count);
    });
}

static void vcamStopOverlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        vcamDetachAllOverlays();
        if (g_maskPlayer) {
            [g_maskPlayer pause];
            g_maskPlayer = nil;
        }
        VCamLog(@"虚拟相机已停止，覆盖层已清理");
    });
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
        dispatch_async(dispatch_get_main_queue(), ^{
            g_vcamEnabled = YES;
            [[MediaManager sharedManager] start];
            vcamStartOverlay(srcUrl);
            if (g_floatButton) g_floatButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9];
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
        g_vcamEnabled = !g_vcamEnabled;
        if (g_floatButton) g_floatButton.backgroundColor = g_vcamEnabled ? [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.9] : [UIColor colorWithRed:0.4 green:0.4 blue:0.4 alpha:0.9];
        if (g_vcamEnabled) {
            [[MediaManager sharedManager] start];
            if (g_selectedVideoUrl) {
                vcamStartOverlay(g_selectedVideoUrl);
            } else {
                VCamLog(@"已开启，但还没选过视频，预览不会被替换");
            }
        } else {
            [[MediaManager sharedManager] stop];
            vcamStopOverlay();
        }
        VCamLog(@"虚拟相机开关切换：%d", g_vcamEnabled);
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

// 相机预览层：系统相机、微信视频通话等一切「把摄像头画面显示出来」的地方都经过它。
// 覆盖层贴在这里，替换的才是真正的预览区域 —— 而不是盲猜一个 window 去盖整屏。
%hook AVCaptureVideoPreviewLayer
- (void)setSession:(AVCaptureSession *)session {
    %orig;
    if (!g_previewLayers) g_previewLayers = [NSHashTable weakObjectsHashTable];
    [g_previewLayers addObject:self];
    VCamLog(@"登记相机预览层 %p session=%p", self, session);
    vcamSyncPreviewOverlay(self);
}
- (void)layoutSublayers {
    %orig;
    // 旋转 / 改变尺寸 / 切前后摄都会触发，用来把覆盖层几何同步过去
    vcamSyncPreviewOverlay(self);
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

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @autoreleasepool {
                setupFloatButton();
                VCamLog(@"悬浮球已创建");
            }
        });
    }
}
