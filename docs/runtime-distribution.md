# 语音运行时分发与许可记录

## 当前可交付运行时

AudiobookMaker 主 App target 仅链接 Apple SDK，工程没有 Swift Package 或第三方二进制依赖。当前生产路径使用 `AVSpeechSynthesizer` 生成本机语音，使用 AVFoundation 封装 M4B；App Sandbox 仅授权用户选择的文件读写，没有网络客户端权限。

这使当前 Intel Mac 可以直接完成 EPUB 导入、语音生成、M4B 封装和 ZIP 导出。语音质量及可用音色取决于用户在 macOS 中安装的系统语音。

## CosyVoice / MLX 边界

参考项目 `/Users/shiye/work/RealReader` 的 CosyVoice 实现依赖 MLX Swift 和 Hugging Face Transformers。MLX 仅适用于 Apple Silicon，因此不能作为当前 Intel 测试机上的可运行后端，也不会静态链接进主 App target。

后续 Apple Silicon 发行版应把推理实现放入单独、签名一致的 XPC Service，并只通过版本化 `TTSRuntimeClient` DTO 交换请求和 App 容器内临时音频文件。主 App 的导入、队列、checkpoint、M4B 和导出逻辑不依赖具体推理框架。

发布 CosyVoice 运行时前仍需完成：

- 固定并审计 MLX Swift、Transformers 与模型权重版本；
- 核对每个依赖和模型权重的再分发许可、署名与隐私声明；
- 配置 XPC Service 的 bundle ID、沙箱、签名、hardened runtime 和公证；
- 在 Apple Silicon 真机完成模型加载、内存峰值、取消、超时、连接失效与离线测试；
- 明确模型是随 App 分发还是由用户手动安装；当前 App 不包含下载器，也没有网络权限。

## 审计命令

```sh
rg "XCRemoteSwiftPackageReference|packageProductDependencies" AudiobookMaker.xcodeproj/project.pbxproj
plutil -p AudiobookMaker/AudiobookMaker.entitlements
```

截至 2026-07-18，三个 target 的 `packageProductDependencies` 均为空，主 App entitlements 只有 App Sandbox 和用户选择文件读写。
