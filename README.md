# IMChat（Flutter 客户端）

IMChat 是 [imserver](https://github.com/fansa91/imchat) 的 iMessage 风格多平台客户端，基于 Flutter 构建，支持 Android、iOS、macOS、Linux、Windows。

- 客户端仓库：[fansa91/imchat-flutter](https://github.com/fansa91/imchat-flutter)
- 服务端仓库：[fansa91/imchat](https://github.com/fansa91/imchat)

## 功能

- 登录 / 注册
- 可编辑的服务器列表（默认 `https://im.fansa.ccwu.cc`）
- 单聊与群聊
- 群管理（成员、群信息等）
- 引用回复
- 表情回应（Reactions）
- 2 分钟内撤回消息
- 仅对自己删除消息
- 语音消息：按住录音，最长 60 秒；已播放 / 已下载的语音永久本地缓存
- 图片消息（v0.3.0）：相册 / 拍照 / 桌面文件选择，长边压缩到 2048px（JPEG 85，GIF 原样）；点击全屏缩放查看并保存；本地永久缓存
- 在线状态（v0.3.0）：单聊显示“在线 / 最后在线”，头像绿点；群聊显示在线人数
- 语音转文字（v0.3.0，需服务端开启 STT）：长按 / 右键语音消息 → 转文字
- 主题色（v0.3.0）：跟随系统壁纸或 8 个预设颜色（与网页端相同）
- 服务端未提供的功能（`/api/config` 无对应开关）自动隐藏
- 已读回执
- 正在输入提示
- Material 3 动态取色，支持浅色 / 深色模式

## 下载

在 [Releases](https://github.com/fansa91/imchat-flutter/releases) 页面下载对应平台的安装包（`<版本>` 为如 `v0.2.0` 的标签名）：

| 平台 | 文件 | 说明 |
| --- | --- | --- |
| Android（推荐） | `imchat-<版本>-android-arm64-v8a.apk` | 绝大多数现代手机 |
| Android | `imchat-<版本>-android-armeabi-v7a.apk` | 较老的 32 位设备 |
| Android | `imchat-<版本>-android-x86_64.apk` | 模拟器 / x86 设备 |
| Android | `imchat-<版本>-android-universal.apk` | 通用包，体积较大 |
| iOS | `imchat-<版本>-ios-unsigned.ipa` | 未签名，需自行侧载 |
| macOS | `imchat-<版本>-macos.dmg` | 未签名 |
| Linux | `imchat-<版本>-linux-x86_64.AppImage` | x86_64 |
| Windows | `imchat-<版本>-windows-x64.zip` | 解压后运行 `imchat.exe` |

## 安装说明

- **Android**：不确定选哪个时，选 `arm64-v8a`；装不上再试 `universal`。
- **iOS**：IPA 未签名，需要使用 [AltStore](https://altstore.io/)、[Sideloadly](https://sideloadly.io/) 或 [TrollStore](https://github.com/opa334/TrollStore) 侧载安装。
- **macOS**：应用未签名 / 未公证。将 `IMChat.app` 拖入「应用程序」后，首次打开请右键 →「打开」；或在终端执行：
  ```bash
  xattr -dr com.apple.quarantine /Applications/IMChat.app
  ```
- **Linux**：
  ```bash
  chmod +x imchat-*-linux-x86_64.AppImage
  ./imchat-*-linux-x86_64.AppImage
  ```
  需要系统安装 `libfuse2`（Ubuntu/Debian：`sudo apt install libfuse2`）。
- **Windows**：解压 zip，运行其中的 `imchat.exe`。

## 本地构建

需要 Flutter 3.47.7（stable）。

```bash
flutter pub get
flutter analyze
flutter test

flutter run                                  # 调试运行
flutter build apk --release --split-per-abi  # Android
flutter build ios --release --no-codesign    # iOS（需 macOS + Xcode）
flutter build macos --release                # macOS
flutter build linux --release                # Linux
flutter build windows --release              # Windows
```

Linux 构建依赖：

```bash
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
```

## Android 签名

1. 运行脚本生成发布密钥（需要 JDK 的 `keytool`）：
   ```bash
   ./scripts/gen-keystore.sh
   ```
2. 按脚本提示，在 GitHub 仓库 **Settings → Secrets and variables → Actions** 中添加 4 个 secrets：
   - `ANDROID_KEYSTORE_BASE64`
   - `ANDROID_KEYSTORE_PASSWORD`
   - `ANDROID_KEY_ALIAS`
   - `ANDROID_KEY_PASSWORD`
3. **务必备份生成的 `imchat-release.jks` 和密码**——丢失后将无法为已安装的应用发布升级版本。

未配置上述 secrets 时，CI 会使用 debug 签名构建 APK（可安装，但不同构建之间可能无法覆盖升级）。

## 发布

推送 `v*` 标签即可触发 GitHub Actions 构建全平台安装包并自动创建 Release：

```bash
git tag v0.2.0 && git push origin v0.2.0
```

也可以在 Actions 页面手动运行 **Release** 工作流（`workflow_dispatch`），此时只上传构建产物（版本号为 `dev-<短 commit>`），不创建 Release。

## 已知限制

- 暂不显示在线状态：服务端目前不广播用户在线 / 离线事件。
- Linux 录制语音依赖系统中的 `parecord`（PulseAudio / PipeWire）和 `ffmpeg`。
- 网页版 Chrome 录制的 webm/opus 语音，在 iOS / macOS / Windows 上可能无法播放。
- 未签名的 macOS 应用可能无法使用钥匙串（Keychain），此时登录 token 会回退保存到本地偏好设置中。
