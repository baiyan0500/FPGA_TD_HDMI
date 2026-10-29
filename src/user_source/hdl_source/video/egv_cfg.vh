// ============================================================================
// egv_cfg.vh — EGV1 视频容器布局常量
//
// 【自动生成，请勿手改】由 tools/video/mp4_to_egv.py 在封装视频后回填。
// 段表来自 exFAT 实际物理分布：TF 卡上 200MB 级文件必然分段，
// FPGA 按裸扇区顺序读，必须知道每一段的物理起点。
//
// 若更换视频，重跑 mp4_to_egv.py 会覆写本文件，然后重新综合。
// ============================================================================
`define EGV_W             320
`define EGV_H             148
`define EGV_FPS           24
`define EGV_FRAMES        1928
`define EGV_BASE_LBA      47360
`define EGV_BLOCK_SECTORS 201
`define EGV_AUDIO_MOD     12
`define EGV_AUDIO_BYTES   8000
`define EGV_VIDEO_BYTES   94720
`define EGV_NRUNS         3

// 每段：数据流逻辑起始扇区（累加值）与对应物理 LBA。
// 文件首扇区是 512B 头，不属于数据流，故 RP0 = 文件起始 LBA + 1，
// 且第一段的数据扇区数比物理段长少 1（RG1 = 段0 扇区数 - 1）。
`define EGV_RG0 0
`define EGV_RP0 47361
`define EGV_RG1 255
`define EGV_RP1 513280
`define EGV_RG2 385279
`define EGV_RP2 905216
// 不足 4 段时用哨兵值，RTL 的比较自然不成立
`define EGV_RG3 32'hFFFFFFFF
`define EGV_RP3 32'hFFFFFFFF
