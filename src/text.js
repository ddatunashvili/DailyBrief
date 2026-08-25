// Reading the files the PowerShell side writes: date-stamped file listings,
// BOM-prefixed JSON, and the mojibake repair those files sometimes need.
// No Electron in here on purpose - this is the part worth unit-testing.

const fs = require('fs');

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function listDates(dir, ext) {
  try {
    return fs.readdirSync(dir)
      .filter((f) => f.endsWith(ext) && DATE_RE.test(f.slice(0, 10)))
      .map((f) => f.slice(0, 10));
  } catch (e) {
    return [];
  }
}

// Repairs text corrupted by an earlier, less-hardened version of the PS
// scripts: UTF-8 bytes misread as Windows-1252, then re-saved as UTF-8.
// Latin-1 round-tripping can't invert that — cp1252 maps bytes 0x80–0x9F
// (present in every Georgian UTF-8 sequence, e.g. 0x83 → U+0192 "ƒ") to
// characters outside Latin-1 — so the reversal needs cp1252's own table.
// Works segment-by-segment on non-ASCII runs so strings that mix clean
// Georgian with mojibake still heal. A run is only replaced when every
// character maps back to a cp1252 byte AND those bytes decode as clean
// multi-byte UTF-8 — a no-op on ASCII/English/already-correct text.
const CP1252_REVERSE = {
  0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85,
  0x2020: 0x86, 0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A,
  0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92,
  0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97,
  0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C,
  0x017E: 0x9E, 0x0178: 0x9F
};

function cp1252Bytes(s) {
  const out = Buffer.alloc(s.length);
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    const b = c <= 0xFF ? c : CP1252_REVERSE[c];
    if (b === undefined) return null;
    out[i] = b;
  }
  return out;
}

function fixMojibake(s) {
  if (typeof s !== 'string' || s.length < 2) return s;
  return s.replace(/[^\x00-\x7F]{2,}/g, (run) => {
    if (/[Ⴀ-ჿ]/.test(run)) return run; // already-correct Georgian
    const bytes = cp1252Bytes(run);
    if (!bytes) return run; // contains chars cp1252 can't produce — not mojibake
    let fixed = bytes.toString('utf8');
    // The original corrupter DROPPED some bytes it couldn't map (e.g. 0x90),
    // leaving an incomplete trailing UTF-8 sequence — decode ends in U+FFFD.
    // That last letter is unrecoverable; strip it rather than keep mojibake.
    fixed = fixed.replace(/�+$/, '');
    // Shorter output proves multi-byte sequences decoded; interior U+FFFD
    // means real garbage — leave those untouched.
    return (fixed.length < run.length && fixed.indexOf('�') === -1) ? fixed : run;
  });
}

// Walks objects/arrays and repairs every string leaf. Returns the SAME
// reference when nothing changed, so callers can cheaply detect "was this
// touched" via `fixed !== original` and only write back when needed.
function deepFixMojibake(value) {
  if (typeof value === 'string') return fixMojibake(value);
  if (Array.isArray(value)) {
    let changed = false;
    const out = value.map((v) => { const f = deepFixMojibake(v); if (f !== v) changed = true; return f; });
    return changed ? out : value;
  }
  if (value && typeof value === 'object') {
    let changed = false;
    const out = {};
    for (const k of Object.keys(value)) {
      const fv = deepFixMojibake(value[k]);
      if (fv !== value[k]) changed = true;
      out[k] = fv;
    }
    return changed ? out : value;
  }
  return value;
}

function readJson(file) {
  try {
    // PS 5.1 tools write UTF-8 with BOM — strip it before parsing.
    const obj = JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
    const fixed = deepFixMojibake(obj);
    // Self-heal: persist the repair so future reads (including the PS
    // scripts themselves) see clean data, not just this one render.
    if (fixed !== obj) {
      try { fs.writeFileSync(file, JSON.stringify(fixed, null, 2), 'utf8'); } catch (e) { /* repair still returned below */ }
    }
    return fixed;
  } catch (e) {
    return null;
  }
}

module.exports = { DATE_RE, listDates, fixMojibake, deepFixMojibake, readJson };
