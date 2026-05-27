'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const qidianMirror = require('../jobs/qidianMirror');

const RANK_KEYS = [
  'fyRank', 'hotRank', 'dsRank', 'recRank', 'updRank',
  'signRank', 'newpRank', 'newbRank', 'newFans',
];
const FINISH_KEYS = ['classic', 'movie', 'bestSell', 'ds'];

function makeValidPayload(overrides = {}) {
  const ranks = Object.fromEntries(RANK_KEYS.map((k) => [k, [{ bid: '1', name: 'a' }].concat(Array(4).fill({ bid: '2', name: 'b' }))]));
  const ranksFemale = Object.fromEntries(RANK_KEYS.map((k) => [k, [{ bid: '1', name: 'a' }].concat(Array(4).fill({ bid: '2', name: 'b' }))]));
  const ranksPublish = Object.fromEntries(['fyRank', 'hotRank', 'newbRank', 'recRank'].map((k) => [k, [{ bid: '6', name: 'p' }, { bid: '7', name: 'q' }, { bid: '8', name: 'r' }]]));
  const finish = Object.fromEntries(FINISH_KEYS.map((k) => [k, [{ bid: '3', name: 'c' }, { bid: '4', name: 'd' }, { bid: '5', name: 'e' }]]));
  const yuepiaoTop50 = Array.from({ length: 20 }, (_, i) => ({ bid: String(100 + i), name: `y${i}` }));
  return { version: Date.now(), ranks, ranksFemale, ranksPublish, finish, yuepiaoTop50, ...overrides };
}

test('validateMirrorPayload accepts complete male payload', () => {
  const r = qidianMirror.validateMirrorPayload(makeValidPayload());
  assert.equal(r.ok, true);
  assert.deepEqual(r.errors, []);
});

test('validateMirrorPayload rejects empty rank list', () => {
  const payload = makeValidPayload();
  payload.ranks.hotRank = [];
  const r = qidianMirror.validateMirrorPayload(payload);
  assert.equal(r.ok, false);
  assert.match(r.errors.join('; '), /ranks\.hotRank/);
});

test('validateMirrorPayload rejects short yuepiaoTop50', () => {
  const payload = makeValidPayload({ yuepiaoTop50: [{ bid: '1', name: 'a' }] });
  const r = qidianMirror.validateMirrorPayload(payload);
  assert.equal(r.ok, false);
  assert.match(r.errors.join('; '), /yuepiaoTop50/);
});

test('validateMirrorPayload rejects missing ranksPublish', () => {
  const payload = makeValidPayload();
  delete payload.ranksPublish;
  const r = qidianMirror.validateMirrorPayload(payload);
  assert.equal(r.ok, false);
  assert.match(r.errors.join('; '), /ranksPublish/);
});

test('validateMirrorPayload validates ranksFemale when present', () => {
  const payload = makeValidPayload({
    ranksFemale: { hotRank: [{ bid: '1', name: 'a' }] },
  });
  const r = qidianMirror.validateMirrorPayload(payload);
  assert.equal(r.ok, false);
  assert.match(r.errors.join('; '), /ranksFemale\.hotRank/);
});
