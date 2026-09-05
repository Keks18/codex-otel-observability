// Uses the optional pinned Grafana dependency described in README.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createRequire } = require('node:module');
const root = path.resolve(__dirname, '..');
const testRequire = createRequire(path.join(root, 'artifacts/grafana-transform-check/package.json'));
const g = testRequire('@grafana/data');
assert.equal(testRequire('@grafana/data/package.json').version, '13.2.0');
const dashboard = JSON.parse(fs.readFileSync(path.join(root, 'grafana/dashboards/codex-overview.json'), 'utf8'));
// Register the same display-name processor used by Grafana's panel editor.
g.standardFieldConfigEditorRegistry.register({
  id: 'displayName', path: 'displayName', name: 'Display name',
  process: g.displayNameOverrideProcessor, shouldApply: () => true,
  settings: { expandTemplateVars: true },
});
const theme = g.createTheme();
const expected = {
  8: { A: 'Duration' },
  9: { A: 'Input', B: 'Cached input', C: 'Output', D: 'Reasoning', E: 'Total', F: 'Non-cached input' },
  10: { A: 'Model sampling' }, 11: { C: 'Model rounds / turn' }, 12: { A: 'Failures' },
  18: { A: 'Calls', B: 'Failures' }, 19: { A: 'p50', B: 'p95', C: 'Max' },
};
let count = 0;
for (const panel of dashboard.panels.filter(p => ['stat', 'timeseries'].includes(p.type))) {
  const names = new Set();
  for (const target of panel.targets.filter(t => !t.hide)) {
    const grouped = [8, 9, 18, 19].includes(panel.id);
    for (const group of grouped ? ['synthetic-alpha', 'synthetic-beta'] : ['']) {
      const label = [8, 9].includes(panel.id) ? 'span.model' : 'event.tool_name';
      const frame = g.createDataFrame({ refId: target.refId, fields: [
        { name: 'time', type: 'time', values: [1788508200000] },
        { name: 'count_over_time', type: 'number', labels: { [label]: group },
          config: { displayNameFromDS: 'avg_over_time' }, values: [1] },
      ] });
      const result = g.applyFieldOverrides({ data: [frame], fieldConfig: panel.fieldConfig, theme,
        // Resolve the documented bracket notation against the field scope.
        replaceVariables: (value, scope) => value.replace(/\$\{__field\.labels\["([^"]+)"\]\}/g,
          (_, key) => scope.__dataContext.value.field.labels?.[key] || ''),
      })[0];
      const name = g.getFieldDisplayName(result.fields[1], result);
      const base = panel.type === 'stat' ? panel.title : expected[panel.id][target.refId];
      assert.equal(name, grouped ? `${base} · ${group}` : base, `Panel ${panel.id}/${target.refId}`);
      assert.ok(!names.has(name), `Series labels must remain distinct in panel ${panel.id}`);
      names.add(name);
      count++;
    }
  }
}
console.log(`Dashboard display names: ${count} synthetic series PASS`);
