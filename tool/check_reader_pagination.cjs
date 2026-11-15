// No Flutter CLI required. Execute the reader's actual JavaScript geometry code.
// --browser-probe writes an isolated DOM regression for a browser/WebView.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(
  path.join(__dirname, '../lib/screens/reader_screen.dart'), 'utf8');
function readerFunction(name) {
  const start = source.indexOf(`  function ${name}(`);
  assert(start >= 0, `Missing ${name}`);
  const end = source.indexOf('\n  }', start);
  return source.slice(start, end + 4);
}
function css(name) {
  return source.split(`static const String ${name} = '''\n`)[1].split("''';")[0];
}
const geometry = ['getScrollContainer', 'getPageStride', 'snapPageWidth',
  'updateLayoutMetrics'].map(readerFunction).join('\n');
const declarations = `let viewportWidth, viewportHeight, pageWidth, pageHeight,
  contentLeft, contentTop, pageStride, pageCount;
  const reader = document.getElementById('reader');
  function measureLineHeightPx() { return 32; }
  ${geometry}`;

if (process.argv.includes('--browser-probe')) {
  // A disposable iframe isolates fixtures from the current book and its styles.
  const html = `<style>${css('_webViewBaseCss')}\n${css('_webViewOverrideCss')}</style>
    <div id="stage"><div id="reader"></div></div>`;
  const body = `${declarations}
    updateLayoutMetrics();
    const fragment = document.createDocumentFragment();
    for (let i = 0; i <= 10000; i++) {
      const column = document.createElement('div');
      column.style.cssText = 'height:var(--page-height);margin:0;padding:0;break-inside:avoid';
      column.textContent = 'Column ' + i;
      fragment.append(column);
    }
    reader.append(fragment);
    updateLayoutMetrics();
    const results = [];
    for (const page of [0, 1, 7092, 10000]) {
      reader.scrollLeft = Math.round(page * pageStride);
      const viewport = reader.getBoundingClientRect();
      const actual = reader.children[page].getBoundingClientRect();
      const next = reader.children[page + 1]?.getBoundingClientRect();
      const drift = actual.left - viewport.left;
      const leak = next ? Math.max(0, viewport.right - next.left) : 0;
      // Native scrolling snaps to physical pixels. Allow its subpixel rounding,
      // but never the multi-pixel drift that previously accumulated with page #.
      const tolerance = 1 / window.devicePixelRatio + 0.01;
      if (Math.abs(drift) > tolerance || leak > tolerance) {
        throw new Error(JSON.stringify({page, pageStride, drift, leak}));
      }
      results.push({page, width: pageWidth, drift, leak});
    }
    return results;`;
  const probe = `(() => {
    const results = [];
    for (const width of [475.4285888671875, 393.142857, 800.5]) {
      const frame = document.createElement('iframe');
      frame.style.cssText = 'position:fixed;left:0;top:0;visibility:hidden;pointer-events:none;border:0;height:500px;width:' + width + 'px';
      document.body.append(frame);
      try {
        const doc = frame.contentDocument;
        doc.open(); doc.write(${JSON.stringify(html)}); doc.close();
        const run = new Function('window', 'document', ${JSON.stringify(body)});
        results.push({availableViewport: width, cases: run(frame.contentWindow, doc)});
      } finally { frame.remove(); }
    }
    return results;
  })()`;
  process.stdout.write(probe);
} else {
  let checks = 0;
  for (const available of [415.4285888671875, 333.142857, 740.5, 360, 0]) {
    const properties = {};
    const reader = {scrollWidth: 10001 * Math.max(1, Math.floor(available))};
    const stage = {getBoundingClientRect: () =>
      ({width: available, height: 400, left: 30, top: 50})};
    const context = vm.createContext({window: {innerWidth: available + 60, innerHeight: 500},
      document: {getElementById: id => id === 'reader' ? reader : stage,
        documentElement: {style: {setProperty: (key, value) => properties[key] = value}}}});
    vm.runInContext(`${declarations}\nupdateLayoutMetrics();`, context);
    const result = vm.runInContext('({pageWidth, pageStride, pageCount, pageHeight})', context);
    assert(Number.isInteger(result.pageWidth) && result.pageWidth >= 1);
    assert.equal(result.pageStride, result.pageWidth);
    assert.equal(result.pageCount, 10001);
    assert.equal(properties['--page-width'], `${result.pageWidth}px`);
    assert.equal(result.pageHeight, 384);
    checks++;
  }
  for (const name of ['_webViewBaseCss', '_webViewOverrideCss']) {
    const readerCss = css(name).match(/#reader \{([^}]+)\}/)[1];
    assert.match(readerCss, /width: var\(--page-width\)/);
    assert.match(readerCss, /column-width: var\(--page-width\)/);
    assert.match(readerCss, /column-gap: 0/);
    checks++;
  }
  // Demonstrate why a serialized computed width must never drive navigation.
  assert(Math.round(7092 * 415.429) - 7092 * 415.4285888671875 > 2);
  checks++;
  const script = source.split("static const String _webViewReaderScript = '''\n")[1]
    .split("''';")[0].replace(/\\\\/g, '\\');
  new vm.Script(script);
  checks++;
  console.log(`PASS ${checks} reader pagination checks; run --browser-probe in a WebView for rendered column checks.`);
}
