const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ethers = require('./vendor/ethers.umd.min.js');

function harness() {
  const html = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');
  const ids = [...html.matchAll(/id="([^"]+)"/g)].map(m => m[1]);
  const elements = Object.fromEntries(ids.map(id => [id, {
    id, disabled: false, value: '', textContent: '', listeners: {},
    addEventListener(event, fn) { (this.listeners[event] ??= []).push(fn); },
    querySelectorAll() { return []; }
  }]));
  const inputs = [...html.matchAll(/<input\b[^>]*id="([^"]+)"/g)].map(m => elements[m[1]]);
  const document = {getElementById: id => elements[id], querySelectorAll: () => inputs};
  const wallet = '0x' + '11'.repeat(20), recipient = '0x' + '22'.repeat(20);
  const receiptAddress = '0x' + '33'.repeat(20), coolerAddress = '0x' + '44'.repeat(20);
  const accountAddresses = ['0x' + '55'.repeat(20), '0x' + '66'.repeat(20)];
  const owners = new Map([[1n, wallet], [2n, wallet]]), simulations = [], transfers = [];
  const transfer = async (from, to, id) => {
    transfers.push(id); owners.set(id, to);
    return {hash: '0xtest', wait: async () => ({status: 1})};
  };
  transfer.staticCall = async (from, to, id) => {
    assert.equal(owners.get(id), from); simulations.push(id);
  };
  const receiptMock = {
    accountOf: async id => accountAddresses[Number(id) - 1] || ethers.ZeroAddress,
    ownerOf: async id => owners.get(id),
    'safeTransferFrom(address,address,uint256)': transfer
  };
  function Contract(address) {
    if (address === coolerAddress) return {accountPosition: async () => ({collateral: 12n, currentDebt: 31n})};
    const index = accountAddresses.indexOf(address);
    assert(index >= 0);
    return {target: address, closed: async () => false, contributedWbtc: async () => BigInt(index + 1) * 100000000n,
      fxPositionId: async () => 0n, price: async () => 100000n * 10n ** 18n};
  }
  const context = vm.createContext({
    window: {ethers: {...ethers, Contract}, LoopQuotes: require('./quotes.js')}, document,
    LOOP_ABI: {}, receiptMock, wallet, receiptAddress, coolerAddress,
    providerMock: {send: async method => method === 'eth_chainId' ? '0x1' : [wallet]}
  });
  vm.runInContext(fs.readFileSync(path.join(__dirname, 'app.js'), 'utf8'), context);
  vm.runInContext('signer = {}; receipt = receiptMock; provider = providerMock; walletAddress = wallet; expectedChain = 1n; loadedReceipt = receiptAddress; addresses = {cooler: coolerAddress};', context);
  elements.receiptAddress.value = receiptAddress; elements.chain.value = '1';
  elements.receiptId.value = '1'; elements.newOwner.value = recipient;
  const evaluate = script => vm.runInContext(script, context);
  const editId = value => {
    elements.receiptId.value = value;
    for (const listener of elements.receiptId.listeners.input) listener();
  };
  return {elements, simulations, transfers, accountAddresses, evaluate, editId};
}

test('editing receipt ID invalidates management until the displayed position is loaded', async () => {
  const h = harness();
  await h.evaluate('run(refresh)');
  assert.equal(h.elements.accountAddress.textContent, `Account ${h.accountAddresses[0]}`);
  assert.equal(h.elements.transfer.disabled, false);
  h.editId('2');
  await h.evaluate('run(transfer)');
  assert.deepEqual(h.transfers, [], 'must not transfer an unreviewed receipt');
  assert.deepEqual(h.simulations, []);
  assert.equal(h.elements.transfer.disabled, true);
  await h.evaluate('run(refresh)');
  assert.equal(h.elements.accountAddress.textContent, `Account ${h.accountAddresses[1]}`);
  assert.equal(h.elements.transfer.disabled, false);
  await h.evaluate('run(transfer)');
  assert.deepEqual(h.simulations, [2n]); assert.deepEqual(h.transfers, [2n]);
});

test('transfer uses the loaded receipt even if input is changed without an input event', async () => {
  const h = harness();
  await h.evaluate('run(refresh)');
  h.elements.receiptId.value = '2';
  await h.evaluate('run(transfer)');
  assert.deepEqual(h.transfers, [], 'verification must bind the ID to the displayed account');
  assert.deepEqual(h.simulations, []);
});

test('invalid or failed position loading cannot retain permission to manage an old account', async () => {
  const h = harness();
  await h.evaluate('run(refresh)');
  h.editId('99');
  await h.evaluate('run(refresh)');
  assert.equal(h.elements.transfer.disabled, true);
  assert.equal(h.elements.addCollateral.disabled, true);
  await h.evaluate('run(transfer)');
  assert.deepEqual(h.transfers, []);
});

test('unchanged loaded receipt transfers its displayed rights', async () => {
  const h = harness();
  await h.evaluate('run(refresh)');
  await h.evaluate('run(transfer)');
  assert.deepEqual(h.simulations, [1n]); assert.deepEqual(h.transfers, [1n]);
  assert.equal(h.elements.transfer.disabled, true);
});
