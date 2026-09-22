# ios-vcam - 开源虚拟相机插件

基于 Theos 的 iOS 越狱插件，Hook 系统相机管线，将自定义视频伪装为实时摄像头画面。

## 功能

- 📷 预览画面替换为所选视频（动态循环播放，不是定格一帧）
- 🖼 拍照、实况照片的静态帧、实况照片的视频部分都替换为假帧
- 🎥 录像：优先在写入层换帧，够不到时改为录完覆盖文件
- 🚫 扫码 / 人脸识别结果屏蔽（识别用的是真实画面，只能让结果不出现在 App 面前）
- 🟢 悬浮按钮 UI（可拖拽，贴边吸附）
- 🆓 无卡密、无网络请求、无 UDID 上传

## 原理与已知限制

替换点在四层，按"能改到真正落盘的那份数据"优先：

| 层 | 挂在哪 | 覆盖 |
| --- | --- | --- |
| 显示 | `AVCaptureVideoPreviewLayer` 上叠 `AVPlayerLayer` | 屏幕预览 |
| 采集 | `AVCaptureVideoDataOutput` 的代理回调（代理类从 output 主动问出来） | 直接读采集数据流的 App 侧逻辑 |
| 写入 | `AVAssetWriterInput appendSampleBuffer:`、`AVAssetWriterInputPixelBufferAdaptor appendPixelBuffer:withPresentationTime:` | 录像、实况照片的视频部分 |
| 元数据 | `AVCaptureMetadataOutput` 的代理回调（结果清空） | 扫码 / 人脸 / 条码 |

**硬性限制**（不是没做，是做不了）：

- **硬件 ISP 仍在采真实画面**。插件改的是软件管线的数据，不是传感器。
- **识别只能"屏蔽结果"**：元数据是检测结论、不是像素，喂不进假帧，只能让 App 收不到。
  所以"镜头前放二维码"在系统层面依旧被识别，只是 App 看不到结果。
- **实况照片的静态帧与视频起点不会时间对齐**（静态帧来自播放头，视频是整段替换）。
- **全景 / 慢动作 / 延时摄影**等模式用的是别的管线，本轮不覆盖。
- **音频仍是真实麦克风**，只换视频帧。
- 第三方 App（微信/QQ 通话）不在当前验证范围内。

## 编译（GitHub Actions 自动编译）

1. 在 GitHub 创建一个新仓库，如 `username/ios-vcam`
2. 推送本项目：

```bash
cd ios-vcam
git add .
git commit -m "init: ios-vcam virtual camera tweak"
git remote add origin https://github.com/limign/ios-vcam.git
git push -u origin main
```

3. CI 自动触发，编译完成后在 Actions → Artifacts 下载：
   - `VCam-deb` — 完整 deb 安装包
   - `VCam-dylib` — 单独的 dylib 文件

> CI 使用 **roothide 版 theos** 编译，产物为 `iphoneos-arm64e` 架构的 roothide 包。
> 本地编译时也需要 roothide 版 theos：`bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"`

## 安装（roothide / Dopamine-roothide）

本插件打包为 roothide 包（`Architecture: iphoneos-arm64e`），只能装在 roothide 环境；
装到普通 rootless 越狱（`iphoneos-arm64`）上会被 dpkg 拒绝，反之亦然。

### 方法 1：deb 安装（推荐）
```bash
# 通过 SSH 传到设备
scp com.yourname.vcam_*_iphoneos-arm64e.deb root@设备IP:/var/tmp/
ssh root@设备IP "dpkg -i /var/tmp/com.yourname.vcam_*_iphoneos-arm64e.deb"
```

用 Sileo 安装也行，但注意 Sileo 里手动导入的 deb 同样受架构校验限制。

### 方法 2：Sileo + RootHide Patcher（把旧的 rootless 包转成 roothide 包）
如果手上只有早前编译的 `iphoneos-arm64` 旧包，可在设备上装
[RootHide Patcher](https://github.com/roothide/RootHidePatcher) 转换后再安装（不是所有包都能转换成功）。

### 方法 3：手动安装 dylib（仅调试用）
必须使用 **roothide 方案编译出来**的 dylib（rootless 版引用的路径在 roothide 下不存在）：
```bash
scp VCam.dylib VCam.plist root@设备IP:/Library/MobileSubstrate/DynamicLibraries/
ssh root@设备IP "killall -9 SpringBoard"
```
roothide 环境下 `/Library/...` 会被自动映射到 jbroot，用 roothide 修补过的 shell 执行即可。

## 使用

1. 安装后任意 App 右上角出现 📷 悬浮按钮
2. 点击 → 「选择视频」→ 从相册选一段视频
3. 点击 → 「开启虚拟相机」
4. 按钮变绿 = 已激活，此时打开任何调用相机的 App 都会看到你的视频

> ⚠️ roothide Bootstrap 默认**不注入 SpringBoard**，悬浮按钮跑不起来。
> 需要先安装 ElleKit，并在 roothide 设置里打开「SpringBoard Injection / 注入 SpringBoard」后重启用户空间。

## 要求

- iOS 14.0+
- 越狱环境：当前构建目标为 **Dopamine-roothide / roothide Bootstrap**（iOS 15.0–16.x）
  - 其他环境（rootless 如 Dopamine 1.x / palera1n rootless）需用
    `make package THEOS_PACKAGE_SCHEME=rootless` 重新编译
- 需要可用的注入器（roothide 上为 ElleKit，Sileo 里安装）

## 技术栈

- Theos + Logos (Objective-C++)
- AVFoundation / CoreMedia / CoreVideo
- MobileSubstrate (Cydia Substrate)

## License

MIT
