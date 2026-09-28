const { test } = require('node:test');
const assert = require('node:assert/strict');
const q = require('./quotes.js');
const a = '0x' + '11'.repeat(20), b = '0x' + '22'.repeat(20), c = '0x' + '33'.repeat(20);
test('route encoding reverses both endpoints and intermediate fees for exact output', () => {
  const forward = q.parseRoute(`${a},500,${b},3000,${c}`, a, c);
  assert.equal(forward, a + '0001f4' + b.slice(2) + '000bb8' + c.slice(2));
  assert.equal(q.parseRoute(`${a},500,${b},3000,${c}`, a, c, true), c + '000bb8' + b.slice(2) + '0001f4' + a.slice(2));
  assert.throws(() => q.parseRoute(`${a},3000,${b}`, a, c));
  assert.throws(() => q.parseRoute(`${a},-1,${b}`, a, b));
  assert.equal(q.parseRoute('', a, a), '0x');
  assert.equal(q.parseRoute(`${a},0,${b}`,a,b), a+'000000'+b.slice(2));
});
test('33 percent requires additional collateral even with optimistic 50 percent reinvestment', () => {
  const extra = q.topUp(0n, 0n, 100000000n, 50000000n, 50000n*q.WAD, 100000n*q.WAD, 0n);
  assert(extra > 1515151n);
});
test('conservative top-up honors supply fees and prior debt', () => {
  for (const fee of [0n, 10000000n, 50000000n]) {
    const top = q.topUp(q.WAD, 33000n*q.WAD, 100000000n, 31250000n, 49500n*q.WAD, 100000n*q.WAD, fee);
    const net = n => n - n*fee/1000000000n;
    const raw = q.WAD + (net(100000000n)+net(31250000n)+net(top))*10000000000n;
    const usd = raw*100000n;
    assert(82500n*q.WAD <= usd*33n/100n);
  }
});
test('slippage and rounding cannot silently loosen user limits', () => {
  assert.equal(q.maximum(101n,100n),103n); assert.equal(q.minimum(101n,100n),99n);
  assert.equal(q.slippage('50'),50n);
  for (const bad of ['0','301','-1','1.5','Infinity','']) assert.throws(() => q.slippage(bad));
});

test('reported fractional close shortfall is included in bridge funding', () => {
  const debt = 2368693941673936653513n, sale = 2368693941660000000000n;
  const cooler = 1400n*q.WAD;
  const funding = q.exitFunding(cooler, debt, sale, 0n);
  assert.equal(funding.flashAmount, cooler + 13936653513n);
  assert.equal(funding.flashAmount - cooler + sale, debt);
  assert.equal(funding.usdsToBuy, funding.flashAmount);
  assert.deepEqual(q.exitFunding(cooler, debt, sale, funding.bridge), {
    bridge: funding.bridge, flashAmount: 0n, usdsToBuy: 0n
  });
});
test('sale surplus and owner contribution reduce flash repayment without negative amounts', () => {
  assert.deepEqual(q.exitFunding(100n, 200n, 250n, 10n), {bridge: 100n, flashAmount: 90n, usdsToBuy: 40n});
  assert.deepEqual(q.exitFunding(100n, 200n, 400n, 0n), {bridge: 100n, flashAmount: 100n, usdsToBuy: 0n});
  assert.throws(() => q.exitFunding(1n, -1n, 0n, 0n));
});
