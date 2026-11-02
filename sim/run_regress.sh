#!/bin/bash
# temporary full regression runner (not for commit)
cd "$(dirname "$0")"
H=../src/user_source/hdl_source
FAIL=0
SUMMARY=/tmp/regress_summary.txt
: > "$SUMMARY"

check() { # $1=name $2=log $3=needle
  if grep -q "$3" "$2"; then
    echo "PASS  $1" | tee -a "$SUMMARY"
  else
    echo "FAIL  $1" | tee -a "$SUMMARY"
    FAIL=1
  fi
  tail -3 "$2" | sed 's/^/      /'
}

# ---- 1. WAV path (6 runs) ----
rm -rf work_wav; vlib work_wav >/dev/null
vlog -quiet -work work_wav eg_logic_bram_sim.v $H/SD/sd_card_wav.v $H/wav_i2s_source.v $H/IP/afifo_16_32_256.v tb_wav_path.v > /tmp/r_wav.log 2>&1 || { echo "COMPILE FAIL wav"; FAIL=1; }
for hdr in 0 1 2; do
  for st in 0 1; do
    vsim -c -quiet work_wav.tb_wav_path -gSTEREO=$st -do "run -all; quit -f" +HDR=$hdr > /tmp/r_wav_${hdr}_${st}.log 2>&1
    check "wav HDR=$hdr STEREO=$st" /tmp/r_wav_${hdr}_${st}.log "PASS"
  done
done

# ---- 2. bmp chain ----
rm -rf work_bmp; vlib work_bmp >/dev/null
vlog -quiet -work work_bmp eg_logic_bram_sim.v $H/SD/bmp_read.v $H/SD/sd_card_wav.v $H/SD/sd_card_bmp.v $H/osd/scaler.v tb_bmp_cycle.v > /tmp/r_bmp.log 2>&1 || { echo "COMPILE FAIL bmp"; FAIL=1; }
vsim -c -quiet work_bmp.tb_bmp_cycle -do "run -all; quit -f" \
  +IMG1=../doc/convert/f_backup/00_1.bmp +IMG2=../doc/convert/f_backup/01_2.bmp \
  +IMG3=../doc/convert/f_backup/02_3.bmp +IMG4=../doc/convert/output_bmp/1_640x480.bmp \
  +IMG5=../doc/convert/output_bmp/2_640x480.bmp +IMG6=../doc/convert/output_bmp/3_640x480.bmp \
  +IMG7=../doc/convert/output_bmp/4_640x480.bmp +IMG8=../doc/convert/output_bmp/5_640x480.bmp \
  +IMG9=../doc/convert/output_bmp/6_640x480.bmp +WAV=$H/python/1.wav > /tmp/r_bmp_run.log 2>&1
check "bmp_cycle" /tmp/r_bmp_run.log "errors=0"

# ---- 2b. 全协议上电复现（真实 SPI 协议栈 + 三客户端仲裁 + wr_fin_split）----
rm -rf work_menu; vlib work_menu >/dev/null
vlog -quiet -work work_menu eg_logic_bram_sim.v $H/SD/spi_master.v $H/SD/sd_card_cmd.v \
  $H/SD/sd_card_sec_read_write.v $H/SD/sd_card_top.v $H/SD/bmp_read.v $H/SD/sd_card_wav.v \
  $H/SD/sd_card_bmp.v $H/osd/scaler.v $H/video/wr_fin_split.v tb_menu_boot.v > /tmp/r_menu.log 2>&1 \
  || { echo "COMPILE FAIL menu"; FAIL=1; }
vsim -c -quiet work_menu.tb_menu_boot -do "run -all; quit -f" > /tmp/r_menu_run.log 2>&1
check "menu_boot" /tmp/r_menu_run.log "TB_MENU_BOOT PASS"

# ---- 3. bmp EGV scan ----
rm -rf work_scan; vlib work_scan >/dev/null
vlog -quiet -work work_scan eg_logic_bram_sim.v $H/SD/bmp_read.v tb_bmp_egv_scan.v > /tmp/r_scan.log 2>&1 || { echo "COMPILE FAIL scan"; FAIL=1; }
vsim -c -quiet work_scan.tb_bmp_egv_scan -do "run -all; quit -f" > /tmp/r_scan_run.log 2>&1
check "bmp_egv_scan" /tmp/r_scan_run.log "PASS"

# ---- 4. SD timing (3 runs) ----
rm -rf work_sd; vlib work_sd >/dev/null
vlog -quiet -work work_sd $H/SD/spi_master.v $H/SD/sd_card_cmd.v $H/SD/sd_card_sec_read_write.v $H/SD/sd_card_top.v tb_sd_timing.v > /tmp/r_sd.log 2>&1 || { echo "COMPILE FAIL sd"; FAIL=1; }
vsim -c -quiet work_sd.tb_sd_timing -do "run -all; quit -f" > /tmp/r_sd_1.log 2>&1
check "sd_timing LAG=1" /tmp/r_sd_1.log "PASS"
vsim -c -quiet work_sd.tb_sd_timing -do "run -all; quit -f" +LAG=0 > /tmp/r_sd_2.log 2>&1
check "sd_timing LAG=0" /tmp/r_sd_2.log "PASS"
vsim -c -quiet work_sd.tb_sd_timing -do "run -all; quit -f" +LAG=1 +DROP=1 > /tmp/r_sd_3.log 2>&1
check "sd_timing LAG=1 DROP=1" /tmp/r_sd_3.log "PASS"

# ---- 5. video ----
rm -rf work_vid; vlib work_vid >/dev/null
vlog -quiet -work work_vid eg_logic_bram_sim.v $H/video/video_frame_fill.v tb_video_frame_fill.v > /tmp/r_vf.log 2>&1 || { echo "COMPILE FAIL video_frame_fill"; FAIL=1; }
vlog -quiet -work work_vid +incdir+$H/video $H/video/egv_reader.v tb_egv_reader.v > /tmp/r_er.log 2>&1 || { echo "COMPILE FAIL egv_reader"; FAIL=1; }
vlog -quiet -work work_vid +incdir+$H/video $H/video/egv_reader.v tb_egv_reader_rt.v > /tmp/r_ert.log 2>&1 || { echo "COMPILE FAIL egv_reader_rt"; FAIL=1; }
vlog -quiet -work work_vid +incdir+$H/video $H/video/egv_reader.v tb_egv_loop.v > /tmp/r_eloop.log 2>&1 || { echo "COMPILE FAIL egv_loop"; FAIL=1; }
vlog -quiet -work work_vid eg_logic_bram_sim.v $H/video/egv_audio_fifo.v tb_egv_audio_fifo.v > /tmp/r_eaf.log 2>&1 || { echo "COMPILE FAIL egv_audio_fifo"; FAIL=1; }
vlog -quiet -work work_vid eg_logic_bram_sim.v $H/video/wr_fin_split.v tb_wr_fin_split.v > /tmp/r_wfs.log 2>&1 || { echo "COMPILE FAIL wr_fin_split"; FAIL=1; }
vsim -c -quiet work_vid.tb_video_frame_fill -do "run -all; quit -f" > /tmp/r_vf_run.log 2>&1
check "video_frame_fill" /tmp/r_vf_run.log "PASS"
vsim -c -quiet work_vid.tb_egv_reader -do "run -all; quit -f" > /tmp/r_er_run.log 2>&1
check "egv_reader" /tmp/r_er_run.log "PASS"
vsim -c -quiet work_vid.tb_egv_reader_rt -do "run -all; quit -f" > /tmp/r_ert_run.log 2>&1
check "egv_reader_rt" /tmp/r_ert_run.log "PASS"
vsim -c -quiet work_vid.tb_egv_loop -do "run -all; quit -f" > /tmp/r_eloop_run.log 2>&1
check "egv_loop" /tmp/r_eloop_run.log "TB_EGV_LOOP PASS"
vsim -c -quiet work_vid.tb_egv_audio_fifo -do "run -all; quit -f" > /tmp/r_eaf_run.log 2>&1
check "egv_audio_fifo" /tmp/r_eaf_run.log "PASS"
vsim -c -quiet work_vid.tb_wr_fin_split -do "run -all; quit -f" > /tmp/r_wfs_run.log 2>&1
check "wr_fin_split" /tmp/r_wfs_run.log "PASS"

# ---- 6. OSD / ctrl / spectrum / misc ----
rm -rf work_osd; vlib work_osd >/dev/null
vlog -quiet -work work_osd eg_logic_bram_sim.v $H/osd/osd_layer.v $H/osd/font8x8.v $H/osd/danmaku_osd.v $H/osd/resmon_osd.v tb_warning_osd.v tb_osd.v > /tmp/r_osd.log 2>&1 || { echo "COMPILE FAIL osd"; FAIL=1; }
vlog -quiet -work work_osd $H/osd/font8x8.v tb_font.v > /tmp/r_font.log 2>&1 || { echo "COMPILE FAIL font"; FAIL=1; }
vlog -quiet -work work_osd eg_logic_bram_sim.v $H/osd/danmaku_osd.v $H/osd/font8x8.v tb_danmaku_osd.v > /tmp/r_dm.log 2>&1 || { echo "COMPILE FAIL danmaku"; FAIL=1; }
vlog -quiet -work work_osd eg_logic_bram_sim.v $H/osd/resmon_osd.v $H/osd/font8x8.v tb_resmon_osd.v > /tmp/r_rm.log 2>&1 || { echo "COMPILE FAIL resmon"; FAIL=1; }
vlog -quiet -work work_osd $H/osd/ctrl.v $H/SD/sd_card_bmp.v tb_ctrl.v > /tmp/r_ctrl.log 2>&1 || { echo "COMPILE FAIL ctrl"; FAIL=1; }
vlog -quiet -work work_osd $H/audio_spectrum.v tb_spectrum.v > /tmp/r_spec.log 2>&1 || { echo "COMPILE FAIL spectrum"; FAIL=1; }
vsim -c -quiet work_osd.tb_warning_osd -do "run -all; quit -f" > /tmp/r_osd_warn.log 2>&1
check "warning_osd" /tmp/r_osd_warn.log "PASS"
vsim -c -quiet work_osd.tb_osd_layer -do "run -all; quit -f" > /tmp/r_osd_run.log 2>&1
check "osd_layer" /tmp/r_osd_run.log "PASS"
vsim -c -quiet work_osd.tb_font -do "run -all; quit -f" > /tmp/r_font_run.log 2>&1
check "font" /tmp/r_font_run.log "lowercase non-zero rows="
vsim -c -quiet work_osd.tb_danmaku_osd -do "run -all; quit -f" > /tmp/r_dm_run.log 2>&1
check "danmaku_osd" /tmp/r_dm_run.log "PASS"
vsim -c -quiet work_osd.tb_resmon_osd -do "run -all; quit -f" > /tmp/r_rm_run.log 2>&1
check "resmon_osd" /tmp/r_rm_run.log "PASS"
vsim -c -quiet work_osd.tb_ctrl -do "run -all; quit -f" > /tmp/r_ctrl_run.log 2>&1
check "ctrl" /tmp/r_ctrl_run.log "PASS"
vsim -c -quiet work_osd.tb_spectrum -do "run -all; quit -f" > /tmp/r_spec_run.log 2>&1
grep -q ">>> FAIL" /tmp/r_spec_run.log && echo "FAIL  spectrum" >> "$SUMMARY" || grep -q ">>> DONE" /tmp/r_spec_run.log && echo "PASS  spectrum" >> "$SUMMARY"; tail -3 /tmp/r_spec_run.log

# ---- 7. 端到端（真实卡上 EGV 数据）----
rm -rf work_e2e; vlib work_e2e >/dev/null
vlog -quiet -work work_e2e eg_logic_bram_sim.v $H/video/egv_reader.v $H/video/video_frame_fill.v tb_e2e_video.v > /tmp/r_e2ev.log 2>&1 || { echo "COMPILE FAIL e2e_video"; FAIL=1; }
vsim -c -quiet work_e2e.tb_e2e_video -do "run -all; quit -f" > /tmp/r_e2ev_run.log 2>&1
check "e2e_video" /tmp/r_e2ev_run.log "TB_E2E_VIDEO PASS"

# 真实卡数据端到端：卡上容器头 + 真实段表 -> egv_reader -> 逐像素比对
# （覆盖运行时表解析、物理地址推进、跨段跳转、音频扇区相位）
vlog -quiet -work work_rr +incdir+$H/video $H/video/egv_reader.v tb_real_reader.v > /tmp/r_rr.log 2>&1 || { echo "COMPILE FAIL real_reader"; FAIL=1; }
vsim -c -quiet work_rr.tb_real_reader -do "run -all; quit -f" > /tmp/r_rr_run.log 2>&1
check "real_reader" /tmp/r_rr_run.log "TB_REAL_READER PASS"

rm -rf work_e2ea; vlib work_e2ea >/dev/null
vlog -quiet -work work_e2ea eg_logic_bram_sim.v $H/video/egv_audio_fifo.v $H/wav_i2s_source.v $H/hdmi_audio_tone_i2s_64fs.v $H/I2S_receiver.v tb_audio_multi.v > /tmp/r_e2ea.log 2>&1 || { echo "COMPILE FAIL audio_multi"; FAIL=1; }
vsim -c -quiet work_e2ea.tb_audio_multi -do "run -all; quit -f" > /tmp/r_am_run.log 2>&1
check "audio_multi" /tmp/r_am_run.log "TB_AUDIO_MULTI PASS"

echo "===================="
cat "$SUMMARY"
echo "FAIL=$FAIL"
