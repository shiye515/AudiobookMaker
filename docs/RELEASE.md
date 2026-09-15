# 发布流程（维护者）

供打 tag、发 GitHub Release、可选公证分发时使用。

## 版本号

- `MARKETING_VERSION`（工程 Target）与 `CHANGELOG.md` 同步
- Git tag：`v1.0.0` 这种语义化版本

## 发布前检查

1. CI 绿色
2. `scripts/verify_epub_split.sh` 通过
3. 本机真实书：导入 → 生成 → M4B 导出 → Books 打开章节正常
4. `CHANGELOG.md` 从 Unreleased 迁到版本段
5. 无密钥、证书、个人 EPUB、模型权重误入仓库

## 打包

```bash
scripts/archive-app.sh build/abm-vX.Y.Z.xcarchive
```

Organizer 或：

```bash
cp ExportOptions.plist.example ExportOptions.plist
# 填 teamID 等
xcodebuild -exportArchive \
  -archivePath build/abm-vX.Y.Z.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

## 公证（直接分发）

```bash
ditto -c -k --keepParent build/export/abm.app abm.zip
xcrun notarytool submit abm.zip --keychain-profile "abm-notary" --wait
xcrun stapler staple build/export/abm.app
spctl -a -vv build/export/abm.app
```

## GitHub Release

- 标题：`vX.Y.Z`
- 正文：粘贴 CHANGELOG 对应段
- 附件：公证后的 `.app` 的 zip（可选）或仅源码自动产物
- 勾选 “Set as the latest release”

## 发布后

- 关闭对应 milestone
- Discussions / README 徽章如需可更新下载链接
