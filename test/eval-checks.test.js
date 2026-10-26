const test = require('node:test');
const assert = require('node:assert');
const C = require('../src/eval-checks');
const { parseArgs, SKIP_RE } = require('../scripts/eval');

const goodBrief = () => ({
  date: '2026-08-26',
  tldr: 'The invoice list is the main thread today.',
  tasks: [
    { id: 'a', title: 'Ship the invoice filter', desc: 'x', weight: 50 },
    { id: 'b', title: 'Finish the deploy history page', desc: 'x', weight: 30 },
    { id: 'c', title: 'Close the mail driver TODO', desc: 'x', weight: 20 }
  ],
  warnings: [],
  recap: [],
  assessment: []
});

test('a well-formed brief has no issues', () => {
  assert.deepStrictEqual(C.validateBrief(goodBrief()), []);
});

test('brief shape problems are each reported', () => {
  const b = goodBrief();
  b.tldr = '';
  b.tasks = b.tasks.slice(0, 2);
  delete b.warnings;
  const issues = C.validateBrief(b);
  assert.ok(issues.some((i) => /tldr/.test(i)));
  assert.ok(issues.some((i) => /expected 3-5, got 2/.test(i)));
  assert.ok(issues.some((i) => /sum to 80/.test(i)));
  assert.ok(issues.some((i) => /warnings missing/.test(i)));
  assert.deepStrictEqual(C.validateBrief(null), ['brief is not a JSON object']);
});

test('weights that are not numbers are caught', () => {
  const b = goodBrief();
  b.tasks[0].weight = 'lots';
  assert.ok(C.validateBrief(b).some((i) => /not a number/.test(i)));
});

test('monitoring task titles are forbidden', () => {
  const bad = C.forbiddenTitles(['Check on the deploy', 'observe RENODE', 'Monitor CI', 'Work out pricing',
    'Ship the filter', 'Checkout flow fix', 'Monitoring dashboard: add CPU chart']);
  assert.deepStrictEqual(bad, ['Check on the deploy', 'observe RENODE', 'Monitor CI', 'Work out pricing']);
});

test('a warning that only cites a score trend is flagged', () => {
  assert.ok(C.isTrendOnlyWarning({ label: 'Slipping', text: 'Activity fell from 129.7 to 116.3 this week.' }));
  assert.ok(C.isTrendOnlyWarning({ text: '3,693.0 -> 239.4 since Monday' }));
  // The same trend next to real evidence is a legitimate warning.
  assert.ok(!C.isTrendOnlyWarning({ text: 'Score 129.7 to 116.3, and `PushDeployJob.php` is still dirty.' }));
  assert.ok(!C.isTrendOnlyWarning({ text: 'Commit b228e93 reverted the invoice fix.' }));
  assert.ok(!C.isTrendOnlyWarning({ text: 'The deploy page has been pending since the 20th.' }));
  assert.strictEqual(C.trendOnlyWarnings([{ text: '10 to 4' }, { text: 'fine' }]).length, 1);
  assert.deepStrictEqual(C.trendOnlyWarnings(undefined), []);
});

test('missingIds lists only ids the board never had', () => {
  assert.deepStrictEqual(C.missingIds(['a', 'b', 'x', 'x', ''], ['a', 'b', 'c']), ['x']);
  assert.deepStrictEqual(C.missingIds(undefined, ['a']), []);
});

test('normal English prose is not flagged', () => {
  const s = C.proseStats('The invoice filter is the main piece of work today. It unblocks the billing page, and the ' +
    'deploy history can follow once the filter ships. A small TODO in the mail driver is left for the afternoon. ' +
    'The rest of the week belongs to the deploy work, which has slipped for a week.');
  assert.deepStrictEqual(s.flags, []);
  assert.ok(s.articleRatio > 0.05);
});

test('caveman prose is flagged', () => {
  const s = C.proseStats('Fix invoice filter. Ship billing page. Deploy history blocked. Mail driver TODO open. ' +
    'Push commit. Check tests pass. Merge branch now. Billing done soon. Deploy next. Review logs. ' +
    'Write migration. Run seed. Update docs fast. Close ticket. Billing priority high. Invoice export broken. ' +
    'Fix export today. Ping client after.');
  assert.ok(s.flags.some((f) => /articles/.test(f)));
  assert.ok(s.flags.some((f) => /short sentences/.test(f)));
});

test('non-Latin text is reported as such, not as caveman', () => {
  const s = C.proseStats('დარჩენილი დღე კვლავ RENODE PANEL-ზე: InvoiceHistory ფილტრი წამყვანი ფოკუსია, შემდეგ Deploy History.');
  assert.deepStrictEqual(s.flags, ['mostly non-English text']);
});

test('briefText gathers every reader-facing string', () => {
  const b = goodBrief();
  b.warnings = [{ sev: 'warn', label: 'L', text: 'warning text' }];
  b.recap = ['recap line'];
  b.assessment = ['assessment paragraph'];
  const t = C.briefText(b);
  for (const s of ['main thread', 'Ship the invoice filter', 'warning text', 'recap line', 'assessment paragraph']) {
    assert.ok(t.includes(s), s);
  }
  assert.strictEqual(C.briefText(null), '');
});

test('parseUsage reads the CLI result line like main.js does', () => {
  const log = 'digest: 26,008 bytes\n' +
    '{"type":"result","is_error":false,"num_turns":1,"duration_ms":41234,"total_cost_usd":0.0712,' +
    '"usage":{"input_tokens":12,"cache_read_input_tokens":3000,"cache_creation_input_tokens":9000,"output_tokens":2100}}\n' +
    '[warn] dropped from model output: x\n[timing] total 57s\n';
  const u = C.parseUsage(log);
  assert.strictEqual(u.inputTokens, 12012);
  assert.strictEqual(u.outputTokens, 2100);
  assert.strictEqual(u.costUsd, 0.0712);
  assert.strictEqual(u.durationMs, 41234);
  assert.strictEqual(u.turns, 1);
  assert.strictEqual(u.scriptSeconds, 57);
  assert.strictEqual(u.skipped, false);
  assert.deepStrictEqual(u.warnings, ['[warn] dropped from model output: x']);
});

test('parseUsage takes the LAST result line and reads skipped runs', () => {
  const two = '{"is_error":true,"usage":{"output_tokens":1}}\n{"is_error":false,"usage":{"output_tokens":7}}';
  assert.strictEqual(C.parseUsage(two).outputTokens, 7);
  const skipped = C.parseUsage('﻿skipped: no activity since last check - zero AI tokens spent\r\n[timing] check total 3s');
  assert.strictEqual(skipped.skipped, true);
  assert.strictEqual(skipped.inputTokens, 0);
  assert.strictEqual(skipped.scriptSeconds, 3);
  assert.strictEqual(C.parseUsage('').skipped, false);
});

test('formatTable pads columns', () => {
  const t = C.formatTable(['a', 'bb'], [['1', '2'], ['333', '']]).split('\n');
  assert.strictEqual(t[0], 'a    bb');
  assert.strictEqual(t[1], '---  --');
  assert.strictEqual(t[2], '1    2');
  assert.strictEqual(t[3], '333');
});

test('eval args: modes, flags and bad input', () => {
  assert.deepStrictEqual(parseArgs([]), { mode: 'all', keep: false, data: '', report: '' });
  assert.strictEqual(parseArgs(['--mode', 'brief']).mode, 'brief');
  assert.strictEqual(parseArgs(['--mode=check', '--keep']).keep, true);
  assert.throws(() => parseArgs(['--mode', 'nope']));
  assert.throws(() => parseArgs(['--frobnicate']));
});

test('the fixture copy leaves scripts, prompts and old run files behind', () => {
  for (const f of ['daily-brief.ps1', 'prompt.md', 'prompt-ask.md', 'strings.json', 'last-run.log',
    'check-digest-ab12.json', 'check-patch-ab12.json', 'brief-out-2026-08-26.json', 'publish.json',
    'execute-request.json', 'dailybrief.db-wal']) {
    assert.ok(SKIP_RE.test(f), f);
  }
  for (const f of ['kanban.json', 'projects.json', 'GOALS.md', 'questions.json', 'top-dirs.txt', 'kanban-archive.json']) {
    assert.ok(!SKIP_RE.test(f), f);
  }
});
