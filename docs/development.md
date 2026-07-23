# 开发与测试说明

## 环境

- Apple Silicon Mac，原生 arm64
- macOS 26 或更高版本
- 完整 Xcode 26，并安装 Metal Toolchain：`xcodebuild -downloadComponent MetalToolchain`
- 项目、App、单元测试和 UI 测试配置均显式使用 `ARCHS=arm64`

## 单元测试

普通 Debug 构建和单元测试可以禁用签名：

```sh
xcodebuild test \
  -project AudiobookMaker.xcodeproj \
  -scheme AudiobookMaker \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:AudiobookMakerTests \
  ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO
```

## UI 测试签名

macOS XCUITest 不得禁用签名。UI test runner 会加入测试 bundle 和框架，必须由 Xcode 使用项目开发证书重新签名，否则 Gatekeeper 会将修改后的 runner 判定为“已损坏”。

```sh
xcodebuild test \
  -project AudiobookMaker.xcodeproj \
  -scheme AudiobookMaker \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:AudiobookMakerUITests \
  ARCHS=arm64
```

## Release

```sh
Tools/archive-apple-silicon.sh
Tools/verify-release-artifacts.sh build/AudiobookMaker-AppleSilicon.xcarchive
```

若已配置 `notarytool` keychain profile：

```sh
NOTARY_PROFILE=AudiobookMaker-notary Tools/archive-apple-silicon.sh
```

归档脚本和 Xcode Release build phase 都会在发布前执行 arm64-only、链接依赖和 bundle 纯净性检查。
