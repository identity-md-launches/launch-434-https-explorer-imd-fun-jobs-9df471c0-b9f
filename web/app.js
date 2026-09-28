/* Runs entirely in the browser with the locally vendored ethers build. */
"use strict";
const $ = id => document.getElementById(id);
const E = window.ethers, Q = window.LoopQuotes;
const ERC20 = ["function decimals() view returns(uint8)", "function symbol() view returns(string)", "function balanceOf(address) view returns(uint256)", "function allowance(address,address) view returns(uint256)", "function approve(address,uint256) returns(bool)"];
const COOLER = ["function loanToValues() view returns(uint96,uint96)", "function minDebtRequired() view returns(uint256)", "function accountPosition(address) view returns(tuple(uint256 collateral,uint256 currentDebt,uint256 maxOriginationDebtAmount,uint256 liquidationDebtAmount,uint256 healthFactor,uint256 currentLtv,uint256 totalDelegated,uint256 numDelegateAddresses,uint256 maxDelegateAddresses))"];
const POOL = ["function getPosition(uint256) view returns(uint256,uint256)", "function priceOracle() view returns(address)"];
const QUOTER = ["function quoteExactInput(bytes,uint256) returns(uint256)", "function quoteExactOutput(bytes,uint256) returns(uint256)"];
const actionIds = ["create", "refresh", "quoteDeposit", "quoteClose", "deposit", "close", "addCollateral", "repayFx", "repayCooler", "transfer", "recover"];
let provider, signer, receipt, account, cfg, addresses, quoter, loadedReceipt, loadedPositionId, expectedChain, walletAddress;
let depositQuote, closeQuote, working = false, isOwner = false, isClosed = false;
const fmt = (x, decimals = 18) => E.formatUnits(x, decimals);
const status = message => { $("status").textContent = message; };
const contract = (address, abi) => new E.Contract(address, abi, signer);
const token = address => contract(address, ERC20);
const asAddress = value => E.getAddress(value.trim());
function invalidate() { depositQuote = closeQuote = undefined; $("deposit").disabled = $("close").disabled = true; }
function clearPosition() {
  account = loadedPositionId = undefined; isOwner = isClosed = false; invalidate();
  $("accountAddress").textContent = "Load a position to manage it.";
  $("owner").textContent = "";
  $("depositPreview").textContent = $("closePreview").textContent = "";
  for (const el of $("metrics").querySelectorAll("strong")) el.textContent = "—";
}
function buttons() {
  for (const input of document.querySelectorAll("input")) input.disabled = working;
  for (const id of actionIds) $(id).disabled = working || !receipt || (id !== "create" && id !== "refresh" && (!account || !isOwner));
  $("deposit").disabled = working || !depositQuote || !isOwner || isClosed;
  $("close").disabled = working || !closeQuote || !isOwner || isClosed;
  for (const id of ["quoteDeposit", "quoteClose", "addCollateral", "repayFx", "repayCooler", "transfer"]) if (isClosed) $(id).disabled = true;
  $("connect").disabled = $("load").disabled = working;
}
async function run(fn) {
  if (working) return;
  working = true; buttons();
  try { await fn(); } catch (error) { status(error.shortMessage || error.reason || error.message || String(error)); }
  finally { working = false; buttons(); }
}
async function verify(requirePosition = true) {
  if (!signer || !receipt) throw Error("Connect and load a deployment first");
  const chain = BigInt(await provider.send("eth_chainId", []));
  const accounts = await provider.send("eth_accounts", []);
  if (chain !== expectedChain || !accounts.length || accounts[0].toLowerCase() !== walletAddress.toLowerCase()
      || asAddress($("receiptAddress").value) !== loadedReceipt || BigInt($("chain").value) !== expectedChain) {
    invalidate(); throw Error("Wallet, chain or deployment changed. Load the deployment again.");
  }
  if (requirePosition) {
    let id;
    try { id = BigInt($("receiptId").value); } catch { /* Reject invalid input below. */ }
    if (!account || loadedPositionId === undefined || id !== loadedPositionId) {
      clearPosition(); throw Error("Receipt ID changed. Load the position before managing it.");
    }
  }
}
async function connect() {
  if (!window.ethereum) throw Error("An EIP-1193 wallet is required");
  provider = new E.BrowserProvider(window.ethereum);
  await provider.send("eth_requestAccounts", []); signer = await provider.getSigner(); walletAddress = await signer.getAddress();
  $("wallet").textContent = `Wallet ${walletAddress} · Chain ${await provider.send("eth_chainId", [])}`;
  $("connect").textContent = walletAddress.slice(0, 6) + "…" + walletAddress.slice(-4);
  status("Wallet connected. Review the deployment addresses before loading.");
}
async function load() {
  if (!signer) await connect();
  expectedChain = BigInt($("chain").value);
  if (expectedChain <= 0n || BigInt(await provider.send("eth_chainId", [])) !== expectedChain) throw Error("Switch the wallet to the expected chain first");
  const address = asAddress($("receiptAddress").value);
  if (await provider.getCode(address) === "0x") throw Error("Receipt has no code on this chain");
  const candidate = contract(address, LOOP_ABI.LoopReceipt);
  const nextConfig = contract(await candidate.config(), LOOP_ABI.LoopConfig);
  await nextConfig.validate();
  const keys = ["wbtc", "fxUSD", "ohm", "gohm", "usds", "manager", "pool", "cooler", "staking", "router", "morpho"];
  const values = await Promise.all(keys.map(k => nextConfig[k]()));
  addresses = Object.fromEntries(keys.map((k, i) => [k, values[i]]));
  const quoterAddress = $("quoterAddress").value.trim() ? asAddress($("quoterAddress").value) : addresses.router;
  if (await provider.getCode(quoterAddress) === "0x") throw Error("Quoter has no code on this chain");
  $("quoterAddress").value = quoterAddress;
  receipt = candidate; cfg = nextConfig; quoter = contract(quoterAddress, QUOTER); loadedReceipt = address;
  clearPosition();
  $("inputToken").value = $("outputToken").value = addresses.wbtc;
  const direct = (from, to) => `${from},3000,${to}`;
  $("depositRoute").value = $("exitOutputRoute").value = "";
  $("ohmRoute").value = direct(addresses.fxUSD, addresses.ohm); $("loopRoute").value = direct(addresses.usds, addresses.wbtc);
  $("exitOhmRoute").value = direct(addresses.ohm, addresses.usds); $("exitFxRoute").value = direct(addresses.usds, addresses.fxUSD);
  $("exitDebtRoute").value = direct(addresses.wbtc, addresses.usds);
  try {
    const bridge = contract(addresses.router,["function usdc() view returns(address)","function fxUSD() view returns(address)"]);
    if ((await bridge.fxUSD()).toLowerCase() === addresses.fxUSD.toLowerCase()) {
      addresses.usdc = await bridge.usdc();
      $("ohmRoute").value = `${addresses.fxUSD},0,${addresses.usdc},3000,${addresses.ohm}`;
      $("exitFxRoute").value = `${addresses.usds},500,${addresses.usdc},0,${addresses.fxUSD}`;
      if (expectedChain === 1n) {
        const weth="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
        $("ohmRoute").value=`${addresses.fxUSD},0,${addresses.usdc},500,${weth},3000,${addresses.ohm}`;
        $("loopRoute").value=`${addresses.usds},3000,${addresses.usdc},500,${addresses.wbtc}`;
        $("exitOhmRoute").value=`${addresses.ohm},3000,${weth},500,${addresses.usdc},3000,${addresses.usds}`;
        $("exitFxRoute").value=`${addresses.usds},3000,${addresses.usdc},0,${addresses.fxUSD}`;
        $("exitDebtRoute").value=`${addresses.wbtc},500,${addresses.usdc},3000,${addresses.usds}`;
      }
    }
  } catch { /* A plain V3 router can be used in local deployments with V3 fxUSD liquidity. */ }
  status("Deployment loaded. Create a receipt or load an existing receipt ID. Review swap routes for available liquidity.");
}
async function waitTx(tx) { status(`Waiting for transaction ${tx.hash}`); const result = await tx.wait(); if (!result || result.status !== 1) throw Error("Transaction failed"); return result; }
async function create() {
  await verify(false); const result = await waitTx(await receipt.createPosition());
  const event = result.logs.map(log => { try { return receipt.interface.parseLog(log); } catch { return null; } }).find(log => log?.name === "PositionCreated");
  if (!event) throw Error("Receipt creation event was not found");
  $("receiptId").value = event.args.id.toString(); await refresh(); status("Position created. Its receipt is in your wallet.");
}
async function refresh() {
  clearPosition(); await verify(false);
  const id = BigInt($("receiptId").value), address = await receipt.accountOf(id);
  if (address === E.ZeroAddress) throw Error("This receipt does not have a position");
  const nextAccount = contract(address, LOOP_ABI.LoopPosition), nextClosed = await nextAccount.closed();
  const owner = nextClosed ? await nextAccount.finalOwner() : await receipt.ownerOf(id);
  const contributions = await nextAccount.contributedWbtc();
  const [raw, debt] = await fxPosition(nextAccount); const cp = await contract(addresses.cooler, COOLER).accountPosition(address);
  let ltv = "price unavailable";
  try { const px = await nextAccount.price(); ltv = debt === 0n ? "0%" : raw === 0n ? "insolvent" : `${Number(debt * 10000n * Q.WAD / (raw * px)) / 100}%`; } catch { /* Direct debt views remain available with a stale oracle. */ }
  account = nextAccount; loadedPositionId = id; isClosed = nextClosed;
  isOwner = owner.toLowerCase() === walletAddress.toLowerCase();
  $("accountAddress").textContent = `Account ${address}`;
  $("owner").textContent = `Owner ${owner} · ${isClosed ? "Closed; receipt burned" : "Active"} · historical contributions ${fmt(contributions, 8)} WBTC`;
  const values = [`${fmt(raw)} WBTC`, `${fmt(debt)} fxUSD / ${ltv}`, `${fmt(cp.collateral)} gOHM / ${fmt(cp.currentDebt)} USDS`];
  [...$("metrics").querySelectorAll("strong")].forEach((el, i) => { el.textContent = values[i]; });
  status(isOwner ? "Position loaded. Quotes use current on-chain balances." : "Read-only: only the receipt owner can manage this position.");
}
async function fxPosition(position = account) { const id = await position.fxPositionId(); return id === 0n ? [0n, 0n] : contract(addresses.pool, POOL).getPosition(id); }
async function fees() {
  const manager = contract(addresses.manager, ["function configuration() view returns(address)"]);
  const c = contract(await manager.configuration(), ["function getPoolFeeRatio(address,address) view returns(uint256,uint256,uint256,uint256)"]);
  const result = await c.getPoolFeeRatio(addresses.pool, account.target);
  if (result.some(x => x >= 1000000000n)) throw Error("Unsupported protocol fee");
  return result;
}
async function deadline() { return BigInt((await provider.getBlock("latest")).timestamp + 600); }
const inputRoute = (id, from, to, reverse = false) => Q.parseRoute($(id).value, from, to, reverse);
async function quoteIn(path, amount) { return path === "0x" ? amount : quoter.quoteExactInput.staticCall(path, amount); }
async function quoteOut(path, amount) { return amount === 0n ? 0n : quoter.quoteExactOutput.staticCall(path, amount); }
async function quoteDeposit() {
  await verify(); invalidate();
  const bps = Q.slippage($("slippage").value), t = asAddress($("inputToken").value);
  if (bps > 100n) throw Error("Deposits require slippage ≤100 bps to remain within the initial 49–50% borrowing band");
  const decimals = await token(t).decimals(), amount = E.parseUnits($("inputAmount").value, decimals);
  if (amount <= 0n) throw Error("Enter a positive deposit amount");
  const inputPath = inputRoute("depositRoute", t, addresses.wbtc), ohmPath = inputRoute("ohmRoute", addresses.fxUSD, addresses.ohm);
  const loopPath = inputRoute("loopRoute", addresses.usds, addresses.wbtc);
  const capitalQuote = await quoteIn(inputPath, amount), minWbtc = inputPath === "0x" ? amount : Q.minimum(capitalQuote, bps);
  const [supplyFee,, borrowFee] = await fees(), px = await account.price();
  const netCapital = minWbtc - minWbtc * supplyFee / 1000000000n;
  // 49.95% leaves a small share-rounding margin within the contract's 49–50% interval.
  const fxBorrow = netCapital * px * 4995n / (100000000n * 10000n);
  const netFx = fxBorrow - fxBorrow * borrowFee / 1000000000n;
  const minOhm = Q.minimum(await quoteIn(ohmPath, netFx), bps);
  const gohm = contract(addresses.gohm, ["function balanceTo(uint256) view returns(uint256)"]);
  const minGohm = await gohm.balanceTo(minOhm);
  const cool = contract(addresses.cooler, COOLER), cp = await cool.accountPosition(account.target), [ltv] = await cool.loanToValues();
  const incrementalCapacity = minGohm * ltv / Q.WAD;
  const capacity = (cp.collateral + minGohm) * ltv / Q.WAD - cp.currentDebt;
  const coolerBorrow = (capacity < incrementalCapacity ? capacity : incrementalCapacity) * 99n / 100n;
  if (coolerBorrow <= 0n || coolerBorrow >= 2n**128n || coolerBorrow + cp.currentDebt < await cool.minDebtRequired()) throw Error("Deposit is too small or the existing Cooler loan needs repayment");
  const minLoopWbtc = Q.minimum(await quoteIn(loopPath, coolerBorrow), bps);
  const [currentRaw, currentDebt] = await fxPosition();
  const priceOracle = contract(await contract(addresses.pool, POOL).priceOracle(), ["function getPrice() view returns(uint256,uint256,uint256)"]);
  const [,poolPrice] = await priceOracle.getPrice();
  const conservativePrice = px < poolPrice ? px : poolPrice;
  const wbtcTopUp = Q.topUp(currentRaw, currentDebt, minWbtc, minLoopWbtc, fxBorrow, conservativePrice, supplyFee);
  const params = {token:t, amount, fxBorrow, coolerBorrow, wbtcTopUp, minWbtc, minOhm, minGohm, minLoopWbtc, deadline:await deadline(), inputPath, ohmPath, loopPath};
  if (minGohm === 0n || minLoopWbtc === 0n) throw Error("Quote rounds to zero");
  depositQuote = {params, account:account.target};
  $("depositPreview").textContent = `Deposit: ${fmt(amount,decimals)} tokens\nMinimum initial WBTC: ${fmt(minWbtc,8)}\nf(x) new debt: ${fmt(fxBorrow)} fxUSD\nMinimum gOHM: ${fmt(minGohm)}\nCooler new debt: ${fmt(coolerBorrow)} USDS\nEntry requires ${fmt(coolerBorrow)} USDS flash liquidity; the Cooler loan repays it.\nMinimum reinvestment: ${fmt(minLoopWbtc,8)} WBTC\nADDITIONAL WBTC FROM YOUR WALLET: ${fmt(wbtcTopUp,8)}\nFinal f(x) LTV must be ≤33% or the entire deposit reverts.\nExpires: ${new Date(Number(params.deadline)*1000).toLocaleTimeString()}`;
  status("Review the additional WBTC and both debts. Approvals authorize this isolated account only.");
}
async function quoteClose() {
  await verify(); invalidate();
  const bps = Q.slippage($("slippage").value), outputToken = asAddress($("outputToken").value);
  const usdsTopUp = E.parseUnits($("exitTopUp").value,18); if (usdsTopUp < 0n) throw Error("USDS contribution cannot be negative");
  const cp = await contract(addresses.cooler,COOLER).accountPosition(account.target), [raw,fxDebt] = await fxPosition();
  const [,withdrawFee,,repayFee] = await fees();
  const ohmToUsdsPath = inputRoute("exitOhmRoute",addresses.ohm,addresses.usds);
  const usdsToFxPath = inputRoute("exitFxRoute",addresses.usds,addresses.fxUSD,true);
  const wbtcToUsdsPath = inputRoute("exitDebtRoute",addresses.wbtc,addresses.usds,true);
  const outputPath = inputRoute("exitOutputRoute",addresses.wbtc,outputToken);
  const gohmBalance = cp.collateral + await token(addresses.gohm).balanceOf(account.target);
  const expectedOhm = await contract(addresses.gohm,["function balanceFrom(uint256) view returns(uint256)"]).balanceFrom(gohmBalance);
  const minOhm = expectedOhm > 1n ? expectedOhm - 1n : expectedOhm;
  const ohmToSell = minOhm + await token(addresses.ohm).balanceOf(account.target);
  const minUsds = ohmToSell === 0n ? 0n : Q.minimum(await quoteIn(ohmToUsdsPath,ohmToSell),bps);
  const fxRepayBudget = fxDebt === 0n ? 0n : fxDebt + Q.ceilDiv(fxDebt*repayFee,1000000000n) + 2n;
  const idleFx = await token(addresses.fxUSD).balanceOf(account.target);
  const buyFx = fxRepayBudget > idleFx ? fxRepayBudget-idleFx : 0n;
  const maxUsdsForFx = Q.maximum(await quoteOut(usdsToFxPath,buyFx),bps);
  const availableUsds = usdsTopUp + await token(addresses.usds).balanceOf(account.target);
  // Reserve 2 bps for debt accrual during the 10-minute quote window.
  const coolerBudget = Q.maximum(cp.currentDebt,2n);
  let {bridge, flashAmount, usdsToBuy} = Q.exitFunding(coolerBudget, maxUsdsForFx, minUsds, availableUsds);
  if ($("noFlash").checked) { if (flashAmount > 0n) throw Error(`Supply at least ${fmt(bridge)} USDS total to exit without flash liquidity`); flashAmount=0n; }
  const maxWbtcForUsds = Q.maximum(await quoteOut(wbtcToUsdsPath,usdsToBuy),bps);
  const grossWbtc = raw/10000000000n;
  const remainingWbtc = grossWbtc-grossWbtc*withdrawFee/1000000000n + await token(addresses.wbtc).balanceOf(account.target) - maxWbtcForUsds;
  if (remainingWbtc < 0n) throw Error("Insufficient collateral to exit at these prices; add USDS and preview again");
  const minOut = remainingWbtc === 0n ? 0n : Q.minimum(await quoteIn(outputPath,remainingWbtc),bps);
  const params = {flashAmount,usdsTopUp,minOhm,minUsds,fxRepayBudget,maxUsdsForFx,maxWbtcForUsds,minOut,deadline:await deadline(),outputToken,ohmToUsdsPath,usdsToFxPath,wbtcToUsdsPath,outputPath};
  closeQuote = {params,account:account.target};
  $("closePreview").textContent = `Full exit; receipt will be burned.\nf(x) repayment budget: ${fmt(fxRepayBudget)} fxUSD\nCooler debt now: ${fmt(cp.currentDebt)} USDS\nFlash USDS: ${fmt(flashAmount)}\nUSDS FROM YOUR WALLET: ${fmt(usdsTopUp)}\nMaximum WBTC sold for repayment: ${fmt(maxWbtcForUsds,8)}\nMinimum returned: ${fmt(minOut,await token(outputToken).decimals())} output tokens\nUnused stablecoins are refunded separately.\nExpires: ${new Date(Number(params.deadline)*1000).toLocaleTimeString()}`;
  status("Review the minimum payout and USDS contribution before unwinding.");
}
async function approve(t, amount) {
  if (amount === 0n) return;
  await verify(); const erc20 = token(t), allowance = await erc20.allowance(walletAddress,account.target);
  if (allowance >= amount) return;
  if (allowance !== 0n) await waitTx(await erc20.approve(account.target,0));
  await verify(); status(`Approve ${fmt(amount,await erc20.decimals())} tokens for ${account.target}`);
  await waitTx(await erc20.approve(account.target,amount));
}
async function submitDeposit() {
  await verify(); const quote = depositQuote; if (!quote || quote.account !== account.target) throw Error("Preview this position again");
  const p = quote.params;
  if (p.token.toLowerCase() === addresses.wbtc.toLowerCase()) await approve(p.token,p.amount+p.wbtcTopUp);
  else { await approve(p.token,p.amount); await approve(addresses.wbtc,p.wbtcTopUp); }
  await verify(); await account.deposit.staticCall(p); await waitTx(await account.deposit(p)); await refresh(); status("Deposit completed. The receipt now represents the updated position.");
}
async function submitClose() {
  await verify(); const quote=closeQuote; if (!quote || quote.account !== account.target) throw Error("Preview this position again");
  await approve(addresses.usds,quote.params.usdsTopUp); await verify(); await account.close.staticCall(quote.params);
  await waitTx(await account.close(quote.params)); await refresh(); status("Both loans settled. Capital returned and receipt burned.");
}
async function manage(kind) {
  await verify(); invalidate(); let args, method;
  if (kind === "addCollateral") { const amount=E.parseUnits($("addWbtc").value,8); if(amount<=0n) throw Error("Positive WBTC required"); await approve(addresses.wbtc,amount); method="addCollateral"; args=[amount]; }
  if (kind === "repayFx") { const amount=E.parseUnits($("repayFxAmount").value,18), fee=(await fees())[3]; if(amount<=0n) throw Error("Positive fxUSD required"); const budget=amount+Q.ceilDiv(amount*fee,1000000000n)+2n; await approve(addresses.fxUSD,budget); method="repayFx"; args=[amount,budget]; }
  if (kind === "repayCooler") { const amount=E.parseUnits($("repayUsdsAmount").value,18); if(amount<=0n) throw Error("Positive USDS required"); await approve(addresses.usds,amount); method="repayCooler"; args=[amount]; }
  if (kind === "recover") { method="recover"; args=[asAddress($("recoverToken").value)]; }
  await verify(); await account[method].staticCall(...args); await waitTx(await account[method](...args)); await refresh(); status("Position updated.");
}
async function transfer() {
  await verify(); const to=asAddress($("newOwner").value); if(to===E.ZeroAddress) throw Error("Recipient cannot be zero");
  const args=[walletAddress,to,loadedPositionId]; await receipt["safeTransferFrom(address,address,uint256)"].staticCall(...args);
  await verify(); await waitTx(await receipt["safeTransferFrom(address,address,uint256)"](...args)); await refresh(); status("All rights to this position transferred with the receipt.");
}
const actions={connect,load,create,refresh,quoteDeposit,quoteClose,deposit:submitDeposit,close:submitClose,transfer};
for (const [id,action] of Object.entries(actions)) $(id).addEventListener("click",()=>run(action));
for (const id of ["addCollateral","repayFx","repayCooler","recover"]) $(id).addEventListener("click",()=>run(()=>manage(id)));
for (const input of document.querySelectorAll("input")) input.addEventListener("input",invalidate);
$("receiptId").addEventListener("input", () => { clearPosition(); buttons(); status("Receipt ID changed. Load the position before managing it."); });
function resetWallet() { signer=receipt=undefined; clearPosition(); buttons(); status("Wallet or network changed. Reconnect and load the deployment again."); }
if(window.ethereum?.on) { window.ethereum.on("accountsChanged",resetWallet); window.ethereum.on("chainChanged",resetWallet); }
buttons();
