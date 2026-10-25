#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Read {tex, display} from a UTF-8 JSON file and write a standalone SVG.
'use strict';

const fs = require('node:fs');

class FormulaError extends Error {}

async function render(tex, display) {
  const {mathjax} = require('@mathjax/src/js/mathjax.js');
  const {TeX} = require('@mathjax/src/js/input/tex.js');
  const {SVG} = require('@mathjax/src/js/output/svg.js');
  const {liteAdaptor} = require('@mathjax/src/js/adaptors/liteAdaptor.js');
  const {RegisterHTMLHandler} = require('@mathjax/src/js/handlers/html.js');
  const {MathJaxNewcmFont} = require('@mathjax/mathjax-newcm-font/js/svg.js');

  // Explicit local extensions: no TeX-driven module or network loading.
  const extensions = {
    ams: 'ams/AmsConfiguration',
    newcommand: 'newcommand/NewcommandConfiguration',
    configmacros: 'configmacros/ConfigMacrosConfiguration',
    color: 'color/ColorConfiguration',
    mathtools: 'mathtools/MathtoolsConfiguration',
    boldsymbol: 'boldsymbol/BoldsymbolConfiguration',
    braket: 'braket/BraketConfiguration',
    cancel: 'cancel/CancelConfiguration',
    enclose: 'enclose/EncloseConfiguration',
    textmacros: 'textmacros/TextMacrosConfiguration',
  };
  for (const module of Object.values(extensions)) {
    require(`@mathjax/src/js/input/tex/${module}.js`);
  }
  mathjax.asyncLoad = (name) => {
    if (!name.startsWith('@mathjax/mathjax-newcm-font/')) {
      throw new Error(`Unsupported dynamic module: ${name}`);
    }
    return Promise.resolve(require(name));
  };
  const adaptor = liteAdaptor();
  RegisterHTMLHandler(adaptor);
  const input = new TeX({
    packages: ['base', ...Object.keys(extensions)],
    formatError: (_jax, error) => { throw new FormulaError(error.message); },
    maxBuffer: 100 * 1024,
  });
  const font = new MathJaxNewcmFont();
  const output = new SVG({font, fontCache: 'none'});
  const document = mathjax.document('', {InputJax: input, OutputJax: output});
  const container = await document.convertPromise(tex, {
    display, em: 10, ex: 10 * font.params.x_height, containerWidth: 800,
  });
  const svg = adaptor.tags(container, 'svg')[0];
  if (!svg) throw new Error('MathJax produced no SVG');
  const box = adaptor.getAttribute(svg, 'viewBox').split(/\s+/).map(Number);
  if (box.length !== 4 || !box.every(Number.isFinite) || box[2] < 0 || box[3] < 0) {
    throw new Error('MathJax produced invalid SVG geometry');
  }
  // MathJax uses 1000 units/em.  The backend expects pt-sized viewBox
  // units, so scale the complete drawing to a 10pt em, preserving baseline 0.
  const scaled = box.map(value => value / 100);
  const [x, y, width, height] = scaled;
  const css = adaptor.textContent(output.styleSheet(document))
    .replace(/mjx-container\[jax="SVG"\]\s*>\s*svg/g, 'svg')
    .replace(/mjx-container\[jax="SVG"\]\s+/g, '');
  const drawing = adaptor.innerHTML(svg);
  return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="${width}pt" height="${height}pt" viewBox="${x} ${y} ${width} ${height}">` +
    `<!--latex-to-svg-backend-x-height ${(10 * font.params.x_height).toFixed(6)}-->` +
    (display ? '' : '<!--latex-to-svg-backend-baseline 0.000000-->') +
    `<style>${css}</style><g transform="scale(0.01)">${drawing}</g></svg>\n`;
}

async function main() {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: node mathjax-render.cjs INPUT.json OUTPUT.svg');
    const request = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
    if (typeof request.tex !== 'string' || typeof request.display !== 'boolean') {
      throw new Error('Input must contain a tex string and a display boolean');
    }
    fs.writeFileSync(process.argv[3], await render(request.tex, request.display), 'utf8');
  } catch (error) {
    const formula = error instanceof FormulaError;
    const message = String(error.message || error).replace(/[\r\n]+/g, ' ');
    console.error(`${formula ? 'MATHJAX_FORMULA_ERROR' : 'MATHJAX_SETUP_ERROR'}: ${message}`);
    if (error.code === 'MODULE_NOT_FOUND') console.error('Run npm ci in the latex-to-svg-backend checkout.');
    process.exitCode = formula ? 2 : 1;
  }
}

if (require.main === module) main();
module.exports = {render};
