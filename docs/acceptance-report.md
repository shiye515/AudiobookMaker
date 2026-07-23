# AudiobookMaker Apple Silicon Edition 验收报告

日期：2026-07-23

当前环境：Mac16,11，24 GiB，macOS 26.5.2，arm64，Xcode 26.6（17F113）

## 当前结论

源码、模型目录、迁移、运行时路由和构建配置已收敛到 Apple 系统语音、CosyVoice3 与 Qwen3-TTS。App 和测试 target 显式使用 arm64；Release build phase 会递归验证 Mach-O 架构、链接依赖、bundle 路径和模型权重。

旧版已移除模型的默认设置、音色、安装记录和未完成任务通过版本化迁移处理。未完成任务不会复用旧 checkpoint；用户重新开始时先删除旧音频目录，再用当前支持模型创建新任务快照。完成任务和既有导出不受影响。

## 2026-07-23 自动化结果

以下 arm64 测试已在本机通过：

- `MigrationFixturesTests`
- `RepositoryModelSettingsTests`
- `DependencyInjectionTests`
- `SpeechSwiftPlatformSupportTests`
- `SpeechSwiftRuntimeTests`
- `ModelPackageManagerMultiModelTests`
- `ModelManifestTests`
- `ConversionCoordinatorTests`

完整 `AudiobookMakerTests` arm64 单元/集成套件随后再次执行并通过。

覆盖内容包括迁移幂等性、路径逃逸/符号链接失败关闭、旧 checkpoint 禁止复用、Apple Speech 生产路由、已移除模型拒绝、平台失败不初始化 session、离线文件校验、同模型 session 复用、模型切换、内存压力卸载、并发安全上限、token/句子切片和取消晚到结果。

arm64 Release build 与 unsigned archive 均已成功，并由 `Tools/verify-release-artifacts.sh` 确认所有 Mach-O 文件仅含 arm64，链接图和 bundle 不含已移除运行时，App bundle 不含模型权重。另已生成 Developer ID Application 签名 archive；`codesign --verify --deep --strict` 与 designated requirement 通过。该候选尚未提交公证，Gatekeeper 当前按预期报告 `Unnotarized Developer ID`。当前 Release App 大小为 178,712,576 字节；历史 Universal 2 基线为 220,315,648 字节。

## 仍需最终环境验收

以下项目不能由本次源码与本机自动化结果替代：

1. 完整 XCUITest 实际执行。更新后的模型 UI 用例已构建并启动，但测试主机无法从 `Running Background` 激活应用，未取得通过结果。
2. 两个真实模型的全量下载、损坏重装、离线试听、暂停/恢复、M4B 导出和人工听感。
3. 将现有 Developer ID 签名候选提交公证、staple，并通过 Gatekeeper。
4. 固定设备的完整冷/热性能重新采集。历史基线缺少热加载字段，比较器会失败关闭。
5. major version、最后一个 Universal 2 版本保留策略和用户公告的维护者决定。

完成条件和命令分别见 `docs/development.md`、`docs/runtime-distribution.md`、`docs/apple-silicon-performance.md` 与 `docs/releases/apple-silicon-edition.md`。
