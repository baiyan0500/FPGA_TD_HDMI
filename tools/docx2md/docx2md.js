#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const mammoth = require('mammoth');
const TurndownService = require('turndown');

const USAGE = `
Usage: node docx2md.js <input...> [options]

  input            one or more .docx files, or directories containing .docx files

Options:
  -o, --out <p>    output file (single input) or output directory (default: same dir as input)
  -t, --txt        emit plain text instead of Markdown
  -r, --recursive  when an input is a directory, also scan subdirectories
      --no-images  do not extract embedded images
  -h, --help       show this help
`;

function parseArgs(argv) {
  const opts = { inputs: [], out: null, txt: false, recursive: false, images: true };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '-h' || a === '--help') { console.log(USAGE.trim()); process.exit(0); }
    else if (a === '-o' || a === '--out') opts.out = argv[++i];
    else if (a === '-t' || a === '--txt') opts.txt = true;
    else if (a === '-r' || a === '--recursive') opts.recursive = true;
    else if (a === '--no-images') opts.images = false;
    else if (a.startsWith('-')) { console.error(`Unknown option: ${a}`); process.exit(2); }
    else opts.inputs.push(a);
  }
  return opts;
}

function collectDocx(input, recursive, acc = []) {
  const st = fs.statSync(input);
  if (st.isFile()) {
    if (input.toLowerCase().endsWith('.docx')) acc.push(input);
    return acc;
  }
  for (const entry of fs.readdirSync(input, { withFileTypes: true })) {
    const p = path.join(input, entry.name);
    if (entry.isDirectory()) {
      if (recursive && entry.name !== 'node_modules') collectDocx(p, recursive, acc);
    } else if (entry.name.toLowerCase().endsWith('.docx') && !entry.name.startsWith('~$')) {
      acc.push(p);
    }
  }
  return acc;
}

function makeTurndown() {
  const td = new TurndownService({
    headingStyle: 'atx',
    hr: '---',
    bulletListMarker: '-',
    codeBlockStyle: 'fenced',
  });

  // Word tables use rowspan/colspan heavily (merged cells). Turndown has no native
  // table support, and a per-cell rule cannot see the spanning neighbours, so the
  // whole <table> is rebuilt here into a GFM grid.
  td.addRule('gfmTable', {
    filter: 'table',
    replacement: (content, node) => {
      const rows = Array.from(node.querySelectorAll('tr'));
      if (rows.length === 0) return content;

      const grid = [];
      rows.forEach((tr, r) => {
        grid[r] = grid[r] || [];
        let c = 0;
        for (const cell of Array.from(tr.children)) {
          if (!/^(TD|TH)$/.test(cell.tagName)) continue;
          while (grid[r][c] !== undefined) c++;
          const text = td.turndown(cell.innerHTML)
            .replace(/\s*\n+\s*/g, ' ')
            .trim()
            .replace(/\|/g, '\\|');
          const colspan = parseInt(cell.getAttribute('colspan') || '1', 10);
          const rowspan = parseInt(cell.getAttribute('rowspan') || '1', 10);
          for (let dr = 0; dr < rowspan; dr++) {
            grid[r + dr] = grid[r + dr] || [];
            for (let dc = 0; dc < colspan; dc++) grid[r + dr][c + dc] = dr === 0 ? text : '';
          }
          c += colspan;
        }
      });

      const cols = Math.max(...grid.map((row) => row.length));
      const line = (row) => {
        const cells = [];
        for (let i = 0; i < cols; i++) cells.push(row && row[i] !== undefined ? row[i] : '');
        return '| ' + cells.join(' | ') + ' |';
      };
      const sep = '| ' + Array(cols).fill('---').join(' | ') + ' |';
      const body = grid.map(line);
      return '\n\n' + body[0] + '\n' + sep + '\n' + body.slice(1).join('\n') + '\n\n';
    },
  });

  return td;
}

async function convertOne(input, opts) {
  const base = path.basename(input).replace(/\.docx$/i, '');
  const outExt = opts.txt ? '.txt' : '.md';

  let outFile;
  if (opts.out) {
    const looksLikeDir = opts.out.endsWith(path.sep) || opts.out.endsWith('/') ||
      (fs.existsSync(opts.out) && fs.statSync(opts.out).isDirectory());
    outFile = looksLikeDir ? path.join(opts.out, base + outExt) : opts.out;
  } else {
    outFile = path.join(path.dirname(input), base + outExt);
  }
  fs.mkdirSync(path.dirname(outFile), { recursive: true });

  const options = {};

  if (!opts.txt && opts.images) {
    const mediaDir = path.join(path.dirname(outFile), base + '.media');
    let counter = 0;
    options.convertImage = mammoth.images.imgElement(async (image) => {
      const ext = (image.contentType || 'image/png').split('/')[1].replace('jpeg', 'jpg');
      const name = `image${++counter}.${ext}`;
      fs.mkdirSync(mediaDir, { recursive: true });
      fs.writeFileSync(path.join(mediaDir, name), await image.read());
      const rel = path.relative(path.dirname(outFile), path.join(mediaDir, name)).split(path.sep).join('/');
      return { src: rel };
    });
  } else {
    options.convertImage = mammoth.images.imgElement(async (image) => ({
      src: `[image: ${image.contentType}]`,
    }));
  }

  let body;
  let messages = [];
  if (opts.txt) {
    const r = await mammoth.extractRawText({ path: input });
    body = r.value.replace(/\n{3,}/g, '\n\n').trim() + '\n';
    messages = r.messages;
  } else {
    const r = await mammoth.convertToHtml({ path: input }, options);
    // Drop the "[image: ...]" text that mammoth leaves when images are skipped.
    const html = r.value.replace(/\[image: image\/\w+\]/g, '');
    body = makeTurndown().turndown(html).replace(/\n{3,}/g, '\n\n').trim() + '\n';
    messages = r.messages;
  }

  const header = opts.txt ? '' : `<!-- source: ${path.basename(input)} -->\n\n`;
  fs.writeFileSync(outFile, header + body, 'utf8');
  return { outFile, messages };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.inputs.length === 0) { console.error(USAGE.trim()); process.exit(2); }

  const files = [];
  for (const inp of opts.inputs) {
    if (!fs.existsSync(inp)) { console.error(`Not found: ${inp}`); process.exit(1); }
    if (fs.statSync(inp).isDirectory() && opts.out && !fs.existsSync(opts.out)) {
      fs.mkdirSync(opts.out, { recursive: true });
    }
    collectDocx(inp, opts.recursive, files);
  }

  if (files.length === 0) { console.error('No .docx files found.'); process.exit(1); }
  if (opts.out && files.length > 1 && !fs.statSync(opts.out).isDirectory()) {
    console.error('--out must be a directory when converting multiple files.');
    process.exit(2);
  }

  let failed = 0;
  for (const f of files) {
    try {
      const { outFile, messages } = await convertOne(f, opts);
      const size = fs.statSync(outFile).size;
      console.log(`OK   ${f}  ->  ${outFile}  (${size} bytes)`);
      for (const m of messages) {
        if (m.type === 'warning') console.log(`     warn: ${m.message}`);
      }
    } catch (e) {
      failed++;
      console.error(`FAIL ${f}: ${e.message}`);
    }
  }
  process.exit(failed ? 1 : 0);
}

main();
