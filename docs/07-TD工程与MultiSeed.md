# TD 工程与 Multi-Seed 流程

## 1. 环境与工程

| 项目 | 值 |
|---|---|
| TD 版本 | Tang Dynasty 6.2.168116 |
| 安装路径 | `D:/TD` |
| 工程文件 | `src/td_project/HDMI1.4b_Transmitter_v1.0.al` |
| 顶层 | `top` |
| 器件 | `EG4S20BG256`（器件库 `eagle_s20.db`） |
| 约束 | `src/user_source/constraints_source/timing.sdc`、`pin.adc` |
| 综合/物理 Run | `syn_1` / `phy_1` |

用 TD 打开 `.al` 即可。工程中的综合/物理策略保持厂商默认，不要随意改约束或 IP。

## 2. 为什么不能用普通 Run

普通 Run 调用 `D:/TD/doc/scripts/DefaultFlow.tcl`。在 `drHoldFix on` 且 `arr_filter false` 时，route 内部会直接做 hold fix。TD 6.2.168116 在默认 seed 下处理约 70 条短 hold 路径（-3~-20ps，集中在 `sd_card_bmp` 行缓存与 WAV FIFO）时访问违例：

```
ERROR: phy_1 exit with code -1073741819
```

对应 Windows `0xC0000005`。该问题在 route 的 `Stage 3 | Hold Fix` 稳定复现，重新只跑 `opt_route` 也会复用同一 `place.db` 再次崩溃。**这不是 RTL 功能错误，也不是时序无法收敛。**

## 3. 正确流程：官方 Multi-Seed

`D:/TD/doc/scripts/MultiSeed.tcl` 的 route 段与 DefaultFlow 不同：先关闭 route 内建 hold fix，route 结束后单独执行 `fix_hold`，从而避开崩溃路径。

### 3.1 GUI 配置

1. 打开 **Flow Runs** 标签页
2. 右键 `phy_1` 行 → **Setup Multi-Seed**
3. 设置：

| 参数 | 值 |
|---|---|
| Enable Multi-Seed | 开 |
| Seed Number | 1 |
| Minimum Seed | **2** |
| Seed Step | 1 |
| Run Jobs | 1 |
| End Step | `bitgen` |
| Generate Bit | 开 |
| Random Seeds | 关 |
| Keep Top Runs Count | 1 |
| Filter | 关（默认） |

4. 右键 `phy_1` → **Launch Runs**

配置保存在 `.al` 的 `<MultiSeed>` 段（不是 `settings.cfg`）：

```xml
<MultiSeed>
    <Property Enable="true" GenBit="true" EndStep="bitgen" Random="false"
              Num="1" Init="2" Jobs="1" Save="1" Step="1">
        <Filter enabled="false">
            <congestion>100</congestion>
            <place_swns>0</place_swns>
            <route_swns>0</route_swns>
        </Filter>
    </Property>
    <Seeds>2 </Seeds>
</MultiSeed>
```

### 3.2 运行现象

- `phy_1` 状态显示 `MultiSeed running`
- 生成 `phy_1/seed_2/settings.cfg`，其中含 `set seed 2`
- 约 6 分钟完成：place ≈52s、route ≈4m39s、fix_hold ≈20s、bitgen ≈7s
- 最佳结果复制到 `phy_1/best_result/`
- 本次结果：Setup +320ps / Hold +24ps / 0 FEPs，93.50% slices（LUT 14831 / 75.67%）

### 3.3 完成后的检查

1. `phy_1/seed_2/flow.status`：Setup/Hold 的 WNS、TNS、FEPs
2. `phy_1/route.qor`：资源与线长
3. `phy_1/HDMI1.4b_Transmitter_v1.0_multiseed_result.csv`：各 seed 汇总
4. `best_result/readMe.txt` 与 bit 是否存在
5. 立即把 bit 复制到 `../../bitstream/`，不要只留在运行目录

本次原始报告已存档到 `docs/reports/`。

## 4. 已知 GUI 行为与注意事项

- **GUI 的普通 Run 会重写 `settings.cfg`**，手工加入的 `set phyWildParams {place seed 2}` 会丢失
- 运行中若 GUI 重置（`seed_2` 被删、`syn_1` 重新运行），不一定是失败；等待整条链跑完，以 `seed_2/flow.status` 为准
- 启动前检查是否误开 **Auto Rerun**、是否选中了不需要的 Run
- 运行目录会被 GUI 清理，**bit 必须单独备份**
- TD GUI 打开时不要同时跑命令行 P&R，避免工程锁冲突
- 修改 RTL 后：先重跑综合，再跑 Multi-Seed；不要复用旧 `place.db`

## 5. 命令行复核方案（可选）

需要在不打开 GUI 的情况下独立验证时，可在 `src/td_project/check_Runs/` 下建立与官方工程同层级的临时 Run（相对路径 `../../../user_source` 才能解析）：

- 复制 `settings.cfg`、`HDMI1.4b_Transmitter_v1.0.prj` 到临时目录
- 综合：`DefaultFlow.tcl`，`start_step read_design`，`end_step opt_gate`
- 物理：`start_step opt_place`，`end_step bitgen`，`parent ../syn_1`
- 在物理 `settings.cfg` 中加入 `set phyWildParams {place seed 2}`

该方案已产出过 +162ps / +3ps 的 bit（md5 `4bb81ba6...`），仅作为交叉验证；**正式出包仍以官方 GUI Multi-Seed 为准**。

## 6. 重建检查清单

- [ ] 确认顶层 `top`、器件 `EG4S20BG256`、约束文件齐全
- [ ] `syn_1` 综合无错误，时序约束被读取
- [ ] `phy_1` 使用 Multi-Seed seed 2，End Step=bitgen
- [ ] `flow.status` 中 Setup/Hold TNS=0、FEPs=0
- [ ] `route.qor` 资源未超限（slices < 95%）
- [ ] bit 复制到 `../../bitstream/` 并记录 md5
- [ ] 上板回归通过后再标记为正式版
