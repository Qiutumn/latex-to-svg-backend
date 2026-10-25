// SPDX-License-Identifier: GPL-3.0-or-later
'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {spawnSync} = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const helper = path.resolve(__dirname, '..', 'mathjax-render.cjs');

function compile(tex, display = true, request) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mathjax test '));
  try {
    const input = path.join(dir, 'equation input.json');
    const output = path.join(dir, 'equation output.svg');
    fs.writeFileSync(input, JSON.stringify(request || {tex, display}));
    const result = spawnSync(process.execPath, [helper, input, output], {
      encoding: 'utf8', cwd: dir, timeout: 30000,
    });
    return {...result, svg: fs.existsSync(output) ? fs.readFileSync(output, 'utf8') : null};
  } finally {
    fs.rmSync(dir, {recursive: true, force: true});
  }
}

test('standalone SVG, font metrics, currentColor and portable geometry', () => {
  const r = compile(String.raw`\frac{a}{b}+\sqrt{x}`);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.svg, /^<svg .*width="[\d.]+pt" height="[\d.]+pt"/);
  assert.match(r.svg, /latex-to-svg-backend-x-height 4.420000/);
  assert.match(r.svg, /<path /);
  assert.match(r.svg, /currentColor/);
  assert.doesNotMatch(r.svg, /<use\b|<foreignObject\b|baseline/);
});

test('inline baseline and distinct display style', () => {
  const inline = compile(String.raw`\sum_{i=1}^n i`, false);
  const display = compile(String.raw`\sum_{i=1}^n i`);
  assert.equal(inline.status, 0, inline.stderr);
  assert.equal(display.status, 0, display.stderr);
  assert.match(inline.svg, /latex-to-svg-backend-baseline 0.000000/);
  assert.notEqual(inline.svg, display.svg);
});

for (const [name, tex] of Object.entries({
  matrix: String.raw`\begin{pmatrix}a&b\\c&d\end{pmatrix}`,
  aligned: String.raw`\begin{aligned}a&=b\\c&=d\end{aligned}`,
  macros: String.raw`\newcommand{\RR}{\mathbb{R}}` + '\n' + String.raw`\RR^2`,
  comments: 'a % preserve the newline\n+b',
  unicode: 'α+β=γ',
  dynamicFont: String.raw`\mathfrak{ABC}+\mathbb{R}`,
  color: String.raw`\color{red}{x}+y`,
  enclosure: String.raw`\enclose{box}{x}`,
  tableRules: String.raw`\begin{array}{|c|c|}\hline a&b\\\hline\end{array}`,
})) {
  test(`renders ${name}`, () => {
    const r = compile(tex);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.svg, /<path /);
    if (name === 'color') assert.match(r.svg, /(?:fill|color)="red"/);
    if (name === 'tableRules') assert.match(r.svg, /stroke-width: 70px/);
  });
}

for (const tex of [String.raw`\notARealCommand{x}`, String.raw`\frac{1}{`,
                   String.raw`\require{https://example.invalid/evil}`]) {
  test(`formula error: ${tex}`, () => {
    const r = compile(tex);
    assert.equal(r.status, 2, r.stderr);
    assert.match(r.stderr, /MATHJAX_FORMULA_ERROR:/);
    assert.equal(r.svg, null);
  });
}

test('bad input is a setup error, not a cached formula error', () => {
  const r = compile('', true, {tex: 42, display: true});
  assert.equal(r.status, 1);
  assert.match(r.stderr, /MATHJAX_SETUP_ERROR:/);
  assert.equal(r.svg, null);
});

test('missing npm dependencies give an actionable setup error', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mathjax missing '));
  try {
    const isolated = path.join(dir, 'mathjax-render.cjs');
    const input = path.join(dir, 'input.json');
    const output = path.join(dir, 'output.svg');
    fs.copyFileSync(helper, isolated);
    fs.writeFileSync(input, JSON.stringify({tex: 'x', display: true}));
    const r = spawnSync(process.execPath, [isolated, input, output], {
      encoding: 'utf8', timeout: 30000, env: {...process.env, NODE_PATH: ''},
    });
    assert.equal(r.status, 1);
    assert.match(r.stderr, /MATHJAX_SETUP_ERROR:/);
    assert.match(r.stderr, /Run npm ci/);
    assert.equal(fs.existsSync(output), false);
  } finally {
    fs.rmSync(dir, {recursive: true, force: true});
  }
});
