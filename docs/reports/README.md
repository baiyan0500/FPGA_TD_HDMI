# 原始 QoR 报告

本目录保存 2026-10-21 两次布局布线的原始报告，供复核与答辩使用。

| 文件 | 来源 | 关键结论 |
|---|---|---|
| `2026-10-21_multiseed_seed2_route.qor` | 官方 GUI Multi-Seed seed 2 | Setup +162ps / Hold +22ps / 0 FEPs；8800 slices |
| `2026-10-21_multiseed_seed2_place.qor` | 同上（place 阶段） | FMAX 175.469MHz；place 后 hold 违例由 fix_hold 修复 |
| `2026-10-21_multiseed_seed2_flow.status` | 同上 | 最终时序与各阶段耗时 |
| `2026-10-21_multiseed_seed2_result.csv` | 同上 | 各 seed 的 SWNS/STNS/HWNS/HTNS 汇总 |
| `2026-10-21_multiseed_seed2_run.log` | 同上 | 完整运行日志（含 bitgen） |
| `2026-10-21_multiseed_seed2_best_result_readMe.txt` | 同上 | best_result 来源说明 |
| `2026-10-21_check_seed2_route.qor` | 命令行独立复核（check_Runs） | Setup +162ps / Hold +3ps；8814 slices |
| `2026-10-21_check_seed2_place.qor` | 同上 | place 阶段 QoR |
| `2026-10-31_wavgv_gate.timing` | check_Runs syn_v8 综合（gate） | Setup -376ps / 14 FEPs、Hold +471ps（P&R 前口径） |
| `2026-10-31_wavgv_gate.area` | 同上 | LUT 15169 / reg 8961 / BRAM 54 / DSP 19 |
| `2026-10-31_wavgv_seed2_route.qor` | check_Runs phy_v8 seed 2 | Setup -22ps / 1 FEP，未采用 |
| `2026-10-31_wavgv_seed3_route.qor` | check_Runs phy_v8 seed 3 | Setup +235ps / Hold +21ps / 0 FEPs；采用 |
| `2026-10-31_wavgv_seed3_place.qor` | 同上（place 阶段） | place 阶段 QoR |
| `2026-10-31_wavgv_seed3_flow.status` | 同上 | 最终时序与各阶段耗时 |
| `2026-10-31_wavgv_seed3_pr.timing` | 同上 | 最终时序明细 |
| `2026-10-31_wavgv_seed3_phy.area` | 同上 | LUT 15530(79.23%) / reg 9110 / LE 16906(86.26%) / BRAM 54 / DSP 19 |

对应 bit 与 md5 见 [验证记录](../05-验证记录.md) 和 `../../../bitstream/README.md`。

> `run.log` 中的 `U3/sdram location ... is not honored` 是导入 `_eco_pr.db` 时的 ECO 放置提示，`pin.adc` 中没有 U3 位置约束；成功运行同样会出现，可忽略。
