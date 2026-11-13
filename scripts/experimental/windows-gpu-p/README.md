# Windows GPU-P experimental reference components

这是从一次 Windows / NVIDIA GPU-P 维护实现中提取的**实验性参考组件**，包含实际使用过的驱动文件事务与 GPU-P 适配器操作代码。宿主开发与离线测试要求 PowerShell 7；客机 PowerShell 5.1 兼容性尚未在本分支验证。它不是可运行的安装器，也没有接入 Cage 的界面、后台、更新或日常启动流程。导入不会执行设备盘点或任何维护阶段；`Integration.ps1` 中所有现场接口默认抛出 `Integration required`，阻止未集成的实时操作。

本分支基于 Cage `61e63f922cb85cc4d100215546a00ed5aeded2ff`。仅新增本目录，不修改正常启动、代理、网络、凭据或客机配置。

## 已知证据与边界

| 项目 | 状态与含义 |
|---|---|
| 本地 RTX 5090 D v2 原始维护实现 | 已完成一次实际 D3D11 HARDWARE 设备创建、所创建设备的 NVIDIA / device ID 核对，以及 2×2 纹理的四像素回读；无 WARP 回退。这是来源实现的硬件证据，不是本导出分支的端到端验收。 |
| 客机任务管理器显示 GPU | 使用者已报告可见；本分支未另行读取任务管理器。 |
| 正常用户会话中的浏览器与桌面加速 | 未完成验收；D3D 成功或任务管理器可见不能证明。 |
| 最终正常冷启动后的同次启动 D3D 与 GUI 复验 | 未完成。 |
| 本分支 | 34 项离线文件/映射检查、9 项模拟的主机适配器检查通过；D3D 源码仅编译和 ABI 检查，未调用 `Run()`。 |
| 其他 NVIDIA 型号 / 驱动版本 | 未实测。按精确设备身份和当前驱动能力解析，不按显卡友好名称或固定型号选择；遇到未知目标路径时拒绝。 |
| AMD、Intel、Linux 客机 | 未实现，不受此驱动提供器支持。 |

不包含性能提升、视频编码、游戏、整桌面渲染或多卡通用兼容性的结论。

## 文件与来源

这些 PowerShell 组件及 D3D11 互操作代码来自该本地维护实现；作为 Cage 贡献按仓库根目录的 [MIT License](../../../LICENSE) 提供。未引入外部 GPU-P 自动安装脚本或驱动二进制。

| 文件 | 保留的实现 |
|---|---|
| `Common.ps1` | 文件身份、哈希、锁定句柄、私有目录、原子日志、目标路径策略、复制决策、精确 PCI / GPU-P 选择。去除了固定机器的 VM 合约。 |
| `Nvidia.ps1` | PnP 与活动 INF/版本/显示类的一致性检查、DISM 多行包解析、精确关联文件与 `CopyToVm` 映射、签名及哈希、完整清单和复制前漂移检查。唯一运行依赖调整是由接口提供 DISM 日志目录。 |
| `Nvidia-TargetPolicy.json` | 固定的 NVIDIA 嵌套目标名称集合。代码校验其内容哈希；该哈希仅约束公开策略文件，不绑定任何机器。未知名称拒绝，清单不能扩大允许集合。 |
| `Guest.ps1` | Prepare → Stage → Apply → VerifyFiles → Rollback 文件事务；保留原有日志、写入前冲突、句柄内部分写入证据、备份/文件身份/ACL/时间检查。去除了固定用户名、VM ID 和 GUI 探测流程。 |
| `Host-Adapter.ps1` | 原有 Attach / RollbackAdapter 与 MMIO 基线检查；导出审查补充了备份记录与实际文件状态均须非空的挂载前检查。仅添加精确 `InstancePath` 的适配器；不改全局分区配额，不执行 DDA。 |
| `Integration.ps1` | 必须由后续集成实现的现场边界，当前全部拒绝执行。 |
| `D3D11Readback.cs` | 原始硬件设备创建、DXGI 身份与四像素回读源码，未改动。没有随附运行包装器。 |
| `Test-Offline.ps1`、`Test-HostAdapter.ps1` | 从原有检查中提取并脱敏的文件测试，以及完全模拟的适配器状态转换测试。 |

未导出现场计划、运行日志、VHD、驱动文件、安装路径、用户/VM 标识、配置/代理内容、账户、密码、可信工具安装器或历史二进制固定值。证据表只保留可以公开的结果描述。

## 实现保留的约束

- 先从 `Win32_PnPSignedDriver` 的 DISPLAY 设备和 `Get-VMHostPartitionableGpu` 分别盘点，再明确选择完整 PnP `DeviceID` 与 GPU-P `InstancePath`。两者必须指向同一 PCI 实例，能力结果必须唯一。没有 `AUTO`、首张显卡、友好名称匹配或固定显示类 `0000`。
- NVIDIA 提供器需要签名的活动显示驱动、匹配的注册表类/INF/版本及 `CopyToVm` 信息。DISM 的多条硬件覆盖行必须属于同一个一致驱动包，不要求每行都等于选中的显卡型号。
- 复制范围是活动 HostDriverStore 包、明确的 System32 / SysWOW64 映射和策略中逐一列出的嵌套目标。嵌套文件还必须关联所选设备，并与活动包文件具有相同文件身份及 SHA-256。主机发布 INF 只有与规范 INF 字节相同时才可排除。
- 拒绝路径穿越、重解析点、写入目标硬链接、缺失/冲突映射、源文件漂移和占用中的目标。`WhenNewer` 不静默降级。允许读取来源驱动包的合法硬链接，不允许借硬链接写入其他目标。
- 目标写入前记录意图；只把持有的独占写句柄所捕获的状态认作本次写入。写入前外部修改、未观测的中断和回滚时的外部漂移均停止，不猜测归属。
- 挂载前要求真实 Off、CPU-only、已验证的客机文件事务、原始 MMIO/cache、有效冷备份和新鲜驱动清单。Saved 不等于 Off。只移除日志中的精确 adapter ID / InstancePath；还原设置前先确认当前值仍等于本次写入值。
- MMIO 参数必须由集成层显式给出并说明依据；不根据 VRAM 自动推导。测试中的 1 / 16 GiB 只是合成用例，不是所有显卡的默认值。

## 后续集成必须补齐的接口

这些接口有意没有默认实现。不要把抛错替换为空函数，也不要把测试中的模拟函数当作运行适配器。

| 接口 | 必须保证的行为 |
|---|---|
| `Assert-CgPlanCurrent(Plan, State)` | 绑定显式选择的主机与 Cage 登记 VM，核对实际状态；固定原 VHD 文件对象/绑定、代数、资源、NIC、安全启动/vTPM、检查点策略；保持原 CPU/动态内存/网络设置。验证已审核的不可变计划、工具字节及必要配置，并在整个阶段持有拒绝写/删的读句柄。返回 `{ VM, Disk }` 的新鲜快照。 |
| `Assert-CgQuiet(Plan)` | 使用 Cage 自身维护/停止流程、实际 Off 和排他的维护所有权，阻止与后台启动/其他维护并发。不得强杀或假定 UI 已退出。挂载过程中仍需防止重新启动。 |
| `Read-CgHostJournal` / `Save-CgHostJournal` | 绑定主机、VM、run 和冻结计划；在私有目录中读取/原子持久化日志，禁止跨运行混用。只有真实冷备份及客机复制后逐文件验证，才能产生 `GuestFilesVerified`。 |
| `Assert-CgGuestAdmin()` | 在精确 VM 的已验证 PowerShell Direct 会话中核对授权管理员身份及 Windows 路径；禁止在宿主运行客机写入阶段。由调用方管理短期凭据，不在文件、参数或日志中记录密码。 |
| `Get-CgGuestRunPath(Plan)` | 检查实际客机身份与计划一致，返回绑定该 run 的新私有目录；拒绝旧运行、路径漂移和不可信重解析点。 |
| `Get-CgHostDiagnosticRoot()` | 返回用户明确选择且已检查的私有本地工作目录，仅供 DISM 日志/临时文件使用；不使用隐含个人路径。 |

主机到客机的传输包装器也未导出：它必须检查 `VMConnectionInfo.VMGuid`，固定并重新检查传输源及可信脚本字节，逐项 BeginStage / 传输 / CompleteStage，再 Apply / VerifyFiles。原 VHD 冷备份、空间预算、维护窗口、正常启动、GUI 验收、主机事件观察和最终冷启动验收都由后续集成负责。全 VHD 恢复不属于这些组件的回滚范围。

`D3D11Readback.Run()` 只证明本次创建的设备与纹理回读，且当前硬件判定限定 NVIDIA。后续包装器必须检查精确选中设备、限制单次子进程时间、保留失败而不回退 WARP，并单独检查普通用户 GUI。实际 Cage、Edge 或 Claude 启动参数也需要核对：禁用 GPU 或强制软件渲染的设置不能由驱动可见性排除。本分支不修改这些参数。不要直接在宿主或未知会话运行探测器。

### 计划与日志的最小数据约定

这是字段约定，不是可应用的示例计划。所有实际身份和路径必须从明确目标的盘点中生成；不随仓库分发现场计划。

| 数据 | 本组件使用的字段 |
|---|---|
| 计划 | `Schema`, `RunId`, `VM`, `Manifest`, `PayloadPins`, `RequestedVmSettings`；完整集成还需主机/磁盘/工具/配置身份及接受条件。 |
| `VM` | 精确 `Id`，原 `GuestControlledCacheTypes`, `LowMemoryMappedIoSpace`, `HighMemoryMappedIoSpace`，以及由集成层检查的完整不变量。 |
| `Manifest` | 由 `Get-CgNvidiaManifest` 生成的 `Active`, `PackageName`, `TargetPolicy`, `Files`, `CopyBytes`, `PackageFiles`, `ExcludedAssociations`, `Catalogs`；不得手写成功标志或跳过来源检查。 |
| `PayloadPins` | 至少包含 `Nvidia-TargetPolicy.json` 的明确名称及内容 SHA-256；集成层须另行固定所有可执行源。 |
| `RequestedVmSettings` | 显式的 cache/low-MMIO/high-MMIO 及记录在完整计划中的依据；数值由集成层校验。 |
| 主机日志 | 真实 `Stage`, `BackupPath`, `Backup`，以及先写意图、后写回读所得的 `MmioStatus`, `MmioBefore`, `MmioAfter`, `Adapter`。 |

日志里的阶段名不是授权。调用者必须验证产生该阶段的实际操作、文件状态和不可变计划；离线测试会直接造这些字段，仅用于状态转换测试。

## 离线检查

在 Windows PowerShell 7、普通本地 NTFS 工作目录中执行。文件测试只在新建的显式目录中创建很小的合成文件；每次使用新目录，完成后保留报告和失败材料供检查。某些沙箱会强制继承额外 ACL，导致私有目录检查拒绝；不能为通过测试而放宽运行时 ACL 规则。

```powershell
$component = Join-Path (Get-Location) 'scripts/experimental/windows-gpu-p'
$output = Join-Path $env:TEMP ('cage-gpu-offline-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File (Join-Path $component 'Test-Offline.ps1') -OutputDirectory $output
pwsh -NoProfile -File (Join-Path $component 'Test-HostAdapter.ps1')
```

文件测试调用真实的文件写入/日志/回滚代码，但把客机身份、目标根和客机目录权限边界重定向到本地测试目录。原生文件身份、ACL 和时间戳检查仍然执行。重解析点/硬链接拒绝用合成元数据检查，没有声称完成原生链接场景验证。所有 CIM、DISM 和 Hyper-V 操作路径均以模拟函数替代；没有客机登录、设备访问、驱动安装、虚拟机启停或浏览器操作。

Windows PowerShell 5.1 兼容性检查未执行：本机脚本执行策略拒绝启动检查脚本，没有绕过或修改策略。已通过的编译、ABI 和事务检查均在 PowerShell 7.6.9 中完成，不等于 5.1 或客机验收。
