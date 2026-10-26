// Pure checks for the eval harness (scripts/eval.js): what a good daily brief
// and a good board patch look like, as code. No fs, no spawn, no AI in here -
// the harness gathers the files, these functions judge them, and the unit
// tests pin the judgement down.

// The prompt forbids monitoring tasks: uncertainty is a question, not a task.
const FORBIDDEN_TITLE_RE = /^\s*(check on|observe|monitor|work out)\b/i;

// "129.7 to 116.3", "3,693.0 -> 239.4": a folder's activity score moving.
const TREND_RE = /\d[\d,]*(?:\.\d+)?\s*(?:to|->|→|=>)\s*\d[\d,]*(?:\.\d+)?/i;

// Concrete evidence a warning may cite instead: a file, a commit hash, code.
const EVIDENCE_RE = /`[^`]+`|\b[\w-]+\.[a-z]{1,5}\b|\b[0-9a-f]{7,40}\b|\b(?:TODO|FIXME)\b/i;

function asArr(v) {
  return Array.isArray(v) ? v : [];
}

// Shape of briefs/<today>.json. Returns a list of problems; empty = valid.
function validateBrief(brief) {
  const issues = [];
  if (!brief || typeof brief !== 'object' || Array.isArray(brief)) return ['brief is not a JSON object'];
  if (typeof brief.tldr !== 'string' || !brief.tldr.trim()) issues.push('tldr missing or empty');
  if (!Array.isArray(brief.tasks)) {
    issues.push('tasks missing');
  } else {
    const n = brief.tasks.length;
    if (n < 3 || n > 5) issues.push('tasks: expected 3-5, got ' + n);
    const weights = brief.tasks.map((t) => Number(t && t.weight));
    if (weights.some((w) => !Number.isFinite(w))) issues.push('tasks: a weight is not a number');
    else {
      const sum = weights.reduce((a, b) => a + b, 0);
      if (sum !== 100) issues.push('tasks: weights sum to ' + sum + ', not 100');
    }
    brief.tasks.forEach((t, i) => {
      if (!t || typeof t.title !== 'string' || !t.title.trim()) issues.push('tasks[' + i + ']: title missing');
    });
  }
  if (!Array.isArray(brief.warnings)) issues.push('warnings missing');
  return issues;
}

function forbiddenTitles(titles) {
  return asArr(titles).filter((t) => FORBIDDEN_TITLE_RE.test(String(t || '')));
}

// A warning whose only content is a score trend: it cites a number moving and
// nothing a human could go and look at.
function isTrendOnlyWarning(w) {
  const text = [w && w.label, w && w.text].filter(Boolean).join(' ');
  return TREND_RE.test(text) && !EVIDENCE_RE.test(text);
}

function trendOnlyWarnings(warnings) {
  return asArr(warnings).filter(isTrendOnlyWarning);
}

// Ids a run referenced that the board did not have before the run.
function missingIds(referenced, existing) {
  const have = new Set(asArr(existing).map(String));
  return Array.from(new Set(asArr(referenced).map(String))).filter((id) => id && !have.has(id));
}

// Every reader-facing sentence of a brief, in one string.
function briefText(brief) {
  if (!brief || typeof brief !== 'object') return '';
  const parts = [brief.tldr];
  asArr(brief.tasks).forEach((t) => parts.push(t && t.title, t && t.desc));
  asArr(brief.warnings).forEach((w) => parts.push(w && w.text));
  asArr(brief.recap).forEach((r) => parts.push(r));
  asArr(brief.assessment).forEach((a) => parts.push(a));
  return parts.filter((p) => typeof p === 'string' && p.trim()).join('\n');
}

// Caveman prose ("Fix bug. Ship invoice. Deploy blocked.") leaked in from a
// user's terse-style hook once. Its fingerprints: next to no articles, and
// very short sentences. Text that is mostly not Latin script is reported as
// such instead - the article test means nothing there.
function proseStats(text) {
  const t = String(text || '').replace(/`[^`]*`/g, ' ').replace(/\*\*/g, '');
  const letters = (t.match(/\p{L}/gu) || []).length;
  const latin = (t.match(/[A-Za-z]/g) || []).length;
  const words = t.match(/[A-Za-z][A-Za-z'-]*/g) || [];
  const sentences = t.split(/[.!?\n]+/).filter((s) => /[A-Za-z]/.test(s));
  const articles = words.filter((w) => /^(the|a|an)$/i.test(w)).length;
  const stats = {
    words: words.length,
    sentences: sentences.length,
    avgWordsPerSentence: sentences.length ? +(words.length / sentences.length).toFixed(1) : 0,
    articleRatio: words.length ? +(articles / words.length).toFixed(3) : 0,
    latinRatio: letters ? +(latin / letters).toFixed(2) : 0,
    flags: []
  };
  if (letters > 0 && stats.latinRatio < 0.5) {
    stats.flags.push('mostly non-English text');
    return stats;
  }
  if (stats.words >= 40 && stats.articleRatio < 0.02) stats.flags.push('almost no articles (caveman-style)');
  if (stats.sentences >= 4 && stats.avgWordsPerSentence < 5) stats.flags.push('very short sentences (caveman-style)');
  return stats;
}

// Mirrors main.js parseUsage: the CLI's own result line is the source of
// truth, cache read/creation count as input, and a run that never reached the
// model starts its log with "skipped:". Duration comes from the result line
// and from the script's own "[timing] ... total Ns" line.
function parseUsage(text) {
  const src = String(text || '');
  const out = {
    inputTokens: 0, outputTokens: 0, costUsd: 0, durationMs: 0, scriptSeconds: 0,
    turns: 0, isError: false, skipped: /^\s*skipped:/.test(src.replace(/^﻿/, '')),
    warnings: []
  };
  const lines = src.split(/\r?\n/);
  let result = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    const s = lines[i].replace(/^﻿/, '').trim();
    if (!s.startsWith('{') || s.indexOf('"is_error"') < 0) continue;
    try { result = JSON.parse(s); break; } catch (e) { /* truncated line */ }
  }
  if (result) {
    const u = result.usage || {};
    out.inputTokens = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
    out.outputTokens = u.output_tokens || 0;
    out.costUsd = Number(result.total_cost_usd) || 0;
    out.durationMs = Number(result.duration_ms) || 0;
    out.turns = Number(result.num_turns) || 0;
    out.isError = !!result.is_error;
  }
  const timing = src.match(/\[timing\][^\n]*?total\s+([\d.,]+)s/g);
  if (timing) {
    const last = timing[timing.length - 1].match(/total\s+([\d.,]+)s/);
    out.scriptSeconds = parseFloat(last[1].replace(/,/g, '')) || 0;
  }
  out.warnings = lines.filter((l) => l.indexOf('[warn]') >= 0).map((l) => l.trim());
  return out;
}

// Plain fixed-width table for the terminal.
function formatTable(headers, rows) {
  const cells = [headers].concat(rows).map((r) => r.map((c) => String(c == null ? '' : c)));
  const widths = headers.map((_, i) => Math.max.apply(null, cells.map((r) => (r[i] || '').length)));
  const line = (r) => r.map((c, i) => (c || '').padEnd(widths[i])).join('  ').trimEnd();
  return [line(cells[0]), widths.map((w) => '-'.repeat(w)).join('  ')]
    .concat(cells.slice(1).map(line)).join('\n');
}

module.exports = {
  validateBrief, forbiddenTitles, isTrendOnlyWarning, trendOnlyWarnings, missingIds,
  briefText, proseStats, parseUsage, formatTable
};
