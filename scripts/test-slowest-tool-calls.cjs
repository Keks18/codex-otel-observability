// Run with Node.js after installing the pinned Grafana test dependency in
// artifacts/grafana-transform-check (see README). Fixtures are synthetic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const root = path.resolve(__dirname, '..');
const testRequire = createRequire(path.join(root, 'artifacts/grafana-transform-check/package.json'));
const grafana = testRequire('@grafana/data');
const { lastValueFrom } = testRequire('rxjs');
assert.equal(testRequire('@grafana/data/package.json').version, '13.2.0');
// Grafana's transformation dispatcher checks this browser context flag.
global.window = {};
for (const transformer of Object.values(grafana.standardTransformers)) {
  if (grafana.standardTransformersRegistry.getIfExists(transformer.id)) continue;
  grafana.standardTransformersRegistry.register({
    id: transformer.id,
    name: transformer.name,
    transformation: () => Promise.resolve(transformer),
  });
}
const dashboardPath = process.argv[2] || path.join(root, 'grafana/dashboards/codex-overview.json');
const panel = JSON.parse(fs.readFileSync(dashboardPath, 'utf8').replace(/^\uFEFF/, '')).panels.find(p => p.id === 15);

function tempoFrame(count, optional = true) {
  const rows = Array.from({ length: count }, (_, i) => i + 1);
  const field = (name, type, displayNameFromDS, value) => ({
    name, type, config: displayNameFromDS ? { displayNameFromDS } : {}, values: rows.map(value),
  });
  return grafana.createDataFrame({
    name: 'Spans', refId: 'A', fields: [
      field('traceIdHidden', 'string', null, n => `trace-${n}`),
      field('traceService', 'string', 'Trace Service', () => 'synthetic-service'),
      field('traceName', 'string', 'Trace Name', () => 'synthetic-trace'),
      field('spanID', 'string', 'Span ID', n => `span-${n}`),
      field('time', 'time', 'Start time', n => 1788508200000 + n * 1000),
      field('name', 'string', 'Name', () => 'dispatch_tool_call_with_terminal_outcome'),
      field('duration', 'number', 'Duration', n => n * 1000000000),
      ...(optional ? [
        field('event.tool_name', 'string', 'event.tool_name', () => 'synthetic-tool'),
        field('event.success', 'string', 'event.success', n => String(n % 2 === 0)),
        field('span.call_id', 'string', 'span.call_id', n => `call-${n}`),
      ] : []),
    ],
  });
}

async function check(count, optional) {
  const transformed = await lastValueFrom(grafana.transformDataFrame(panel.transformations, [tempoFrame(count, optional)]));
  assert.equal(transformed.length, 1, 'The span table must survive transformations');
  const frame = transformed[0];
  assert.equal(frame.length, Math.min(count, 20), 'Keep rows, limited to the slowest 20');
  const duration = frame.fields.find(f => f.name === 'duration');
  assert.ok(duration, 'Duration must survive even without optional attributes');
  assert.deepEqual(duration.values, Array.from({ length: Math.min(count, 20) }, (_, i) => (count - i) * 1000000000), 'Sort numerically before limiting');
  const trace = frame.fields.find(f => f.name === 'traceIdHidden');
  assert.deepEqual(trace.values, Array.from({ length: Math.min(count, 20) }, (_, i) => `trace-${count - i}`), 'Trace IDs must stay aligned with sorted calls');
  for (const name of ['name', 'traceName', 'traceService']) {
    assert.ok(!frame.fields.some(f => f.name === name), `Exclude ${name} using its Tempo display name`);
  }
  if (optional) {
    assert.deepEqual(frame.fields.slice(0, 4).map(f => f.name), ['event.tool_name', 'duration', 'event.success', 'span.call_id']);
  }
  const traceOverride = panel.fieldConfig.overrides.find(o => o.matcher.options === trace.name);
  const links = traceOverride.properties.find(p => p.id === 'links').value;
  assert.ok(links.some(link => link.internal?.datasourceUid === 'tempo' && link.internal.query.query === '${__value.raw}'), 'Preserve Tempo Trace ID links');
  const durationOverride = panel.fieldConfig.overrides.find(o => o.matcher.options === duration.name);
  assert.equal(durationOverride.properties.find(p => p.id === 'unit').value, 'ns', 'Search table durations are nanoseconds');
}

(async () => {
  await check(25, true);
  await check(3, false);
  await check(0, false);
  console.log('Slowest tool calls: top 20, numeric sorting, missing optional fields, empty data, Trace ID links PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
