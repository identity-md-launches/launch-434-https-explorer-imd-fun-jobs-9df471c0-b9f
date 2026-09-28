/* Pure quote arithmetic, shared by the browser and offline Node tests. All amounts are bigint. */
(function (root) {
  const WAD = 10n ** 18n;
  const ceilDiv = (a, b) => { if (b <= 0n || a < 0n) throw Error("Invalid quote arithmetic"); return (a + b - 1n) / b; };
  const minimum = (amount, bps) => amount * (10000n - bps) / 10000n;
  const maximum = (amount, bps) => ceilDiv(amount * (10000n + bps), 10000n);
  function slippage(value) {
    if (!/^\d+$/.test(value)) throw Error("Slippage must be whole basis points");
    const bps = BigInt(value);
    if (bps < 1n || bps > 300n) throw Error("Use 1 to 300 basis points of slippage");
    return bps;
  }
  function parseRoute(text, first, last, reverse = false) {
    const address = /^0x[0-9a-fA-F]{40}$/;
    if (first.toLowerCase() === last.toLowerCase()) {
      if (text.trim()) throw Error("Leave the route empty when both tokens match");
      return "0x";
    }
    const parts = text.trim().split(/\s*,\s*/);
    if (parts.length < 3 || parts.length > 21 || parts.length % 2 !== 1) throw Error("Route: token, fee, token, … (up to 10 hops)");
    if (parts[0].toLowerCase() !== first.toLowerCase() || parts.at(-1).toLowerCase() !== last.toLowerCase()) throw Error("Route endpoints do not match the selected tokens");
    for (let i = 0; i < parts.length; i++) {
      if (i % 2 === 0) { if (!address.test(parts[i])) throw Error("Invalid route token"); }
      else if (!/^\d+$/.test(parts[i]) || BigInt(parts[i]) > 0xffffffn) throw Error("Invalid route fee");
    }
    if (reverse) parts.reverse();
    return "0x" + parts.map((v, i) => i % 2 ? BigInt(v).toString(16).padStart(6, "0") : v.slice(2).toLowerCase()).join("");
  }
  // Raw f(x) collateral uses 18 decimals. WBTC and the displayed top-up use 8.
  function topUp(currentRaw, currentDebt, capitalMin, loopMin, newDebt, px, supplyFee) {
    if (supplyFee < 0n || supplyFee >= 10n ** 9n || px <= 0n) throw Error("Invalid protocol parameters");
    const denominator = 10n ** 9n;
    const credit = n => (n - n * supplyFee / denominator) * 10n ** 10n;
    const targetRaw = ceilDiv(ceilDiv((currentDebt + newDebt) * 100n, 33n) * WAD, px);
    const shortfall = targetRaw - currentRaw - credit(capitalMin) - credit(loopMin);
    return shortfall <= 0n ? 0n : ceilDiv(ceilDiv(shortfall, 10n ** 10n) * denominator, denominator - supplyFee) + 2n;
  }
  // Rounded OHM proceeds may be a few wei below fxUSD debt even without price movement.
  // That gap must be funded BEFORE f(x) releases the WBTC collateral.
  function exitFunding(coolerBudget, maxUsdsForFx, minSale, availableUsds) {
    if ([coolerBudget, maxUsdsForFx, minSale, availableUsds].some(x => x < 0n)) throw Error("Negative exit amount");
    const shortfall = maxUsdsForFx > minSale ? maxUsdsForFx - minSale : 0n;
    const bridge = coolerBudget + shortfall;
    const flashAmount = bridge > availableUsds ? bridge - availableUsds : 0n;
    const totalCost = coolerBudget + maxUsdsForFx, saleFunds = minSale + availableUsds;
    const usdsToBuy = flashAmount > 0n && totalCost > saleFunds ? totalCost - saleFunds : 0n;
    return { bridge, flashAmount, usdsToBuy };
  }
  const api = { WAD, ceilDiv, minimum, maximum, slippage, parseRoute, topUp, exitFunding };
  if (typeof module !== "undefined") module.exports = api; else root.LoopQuotes = api;
})(globalThis);
