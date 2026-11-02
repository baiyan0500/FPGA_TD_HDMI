const fs = require('fs');
function parse(f) {
  const out = {};
  for (const line of fs.readFileSync(f, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|/);
    if (m) out[m[1] + '/' + m[2]] = [+m[3], +m[4], +m[5], +m[6], +m[7]];
  }
  return out;
}
const a = parse('../docs/reports/2026-10-31_wavgv_gate.area');
const b = parse('../src/td_project/check_Runs/syn_v13/HDMI1.4b_Transmitter_v1.0_gate.area');
const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
const rows = [];
for (const k of keys) {
  const x = a[k] || [0, 0, 0, 0, 0], y = b[k] || [0, 0, 0, 0, 0];
  const dl = y[0] + y[1] - x[0] - x[1];
  if (Math.abs(dl) >= 20) rows.push([dl, k, 'lut ' + x[0] + '->' + y[0], 'rip ' + x[1] + '->' + y[1], 'seq ' + x[2] + '->' + y[2], 'bram ' + x[3] + '->' + y[3], 'dsp ' + x[4] + '->' + y[4]]);
}
rows.sort((p, q) => Math.abs(q[0]) - Math.abs(p[0]));
for (const r of rows.slice(0, 20)) console.log(r.join('  '));
