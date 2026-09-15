# Vendor: speech-swift

本地化副本（基于上游 commit `d655076badd143f99c9ce19642fbea8b643ccc0b`），用于修复 **Xcode GUI Archive** 在 x86_64 切片上编译 `CosyVoiceTTS` 失败的问题。

## 补丁

`Sources/CosyVoiceTTS/CamPlusPlusSpeaker.swift`：

- `MLMultiArray` 数据类型 `.float16` → `.float32`
- 指针绑定 `Float16` → `Float`

原因：Swift `Float16` 在 **x86_64 macOS** 上标记为 unavailable。Debug/Build 只编 arm64 看不出来；Archive（`generic/platform=macOS`）会给 SPM 包拉起 x86_64 切片，在此炸掉。CoreML 的 float32 multiarray 在全架构可用，功能等价。

## 同步上游

```bash
# 从上游拉取后重新套补丁（勿直接覆盖丢掉 float32 修改）
git clone https://github.com/soniqo/speech-swift /tmp/speech-swift
rsync -a --delete --exclude CamPlusPlusSpeaker.swift \
  /tmp/speech-swift/Sources/ Vendor/speech-swift/Sources/
# 再手工核对 CamPlusPlusSpeaker 的 float32 补丁
```

工程通过 `XCLocalSwiftPackageReference` 引用 `Vendor/speech-swift`，不再远程 pin speech-swift。
