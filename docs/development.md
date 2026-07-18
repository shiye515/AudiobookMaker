# 开发与测试说明

## Xcode 测试签名

- 普通 Debug 构建和单元测试可以在命令行使用 `CODE_SIGNING_ALLOWED=NO`。
- macOS XCUITest 不得禁用签名。UI test runner 会在构建时加入测试 bundle 和框架，必须由 Xcode 使用项目开发证书重新签名，否则 Gatekeeper 会将修改后的 runner 判定为“已损坏”。

UI 测试使用：

```sh
xcodebuild \
  -project AudiobookMaker.xcodeproj \
  -scheme AudiobookMaker \
  -configuration Debug \
  -destination 'platform=macOS' \
  test \
  -only-testing:AudiobookMakerUITests
```

不要在该命令中加入 `CODE_SIGNING_ALLOWED=NO`。
