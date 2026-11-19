/* SteadyStack frontend — read-only live data from Lasna + Base Sepolia.
   No wallet, no transactions, no secrets. Every number comes from a public
   RPC eth_call / eth_getLogs, or from the pre-indexed buys.json (decoded from
   on-chain events) plus a live tail scan. A failed read shows "unavailable"
   with the reason — never a mock or stale number presented as live. */
"use strict";

if (typeof BigInt === "undefined") {
  document.getElementById("compat-banner").hidden = false;
  throw new Error("BigInt unavailable");
}

/* ---------- constants (all verified on-chain) ---------- */

var REACTIVE = "0xdcF6cccD1d6eC0f071409f6e09989AE637CC501f"; // Lasna
var VAULT = "0xdcF6cccD1d6eC0f071409f6e09989AE637CC501f"; // Base Sepolia
var POOL = "0x46880b404cd35c165eddeff7421019f8dd25f4ad";
var USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e"; // Base Sepolia USDC
var WETH = "0x4200000000000000000000000000000000000006"; // Base Sepolia WETH

var LASNA_RPC = "https://lasna-rpc.rnk.dev/";
var BASE_RPCS = [
  "https://base-sepolia.publicnode.com", // primary: 5000-block eth_getLogs chunks
  "https://sepolia.base.org", // fallback: 200-block chunks
];
var BASE_CHUNK = [5000, 200]; // per-RPC eth_getLogs range cap, same order as BASE_RPCS

var SEL = {
  rule: "0x25e3d522",
  lastPrice: "0x053f14da",
  emaPrice: "0xae34031d",
  referencePrice: "0x59414bf2",
  guardTripped: "0xee352c31",
  tickCount: "0xb9ffc934",
  lastBuyTick: "0x2d09bcd5",
  buyRequests: "0x8c1d347e",
  debt: "0x0dca59c1",
  paused: "0x5c975abb",
  buyCount: "0xca703075",
  totalUsdcSpent: "0xef5802ac",
  totalWethBought: "0xcd6b4f9d",
  slot0: "0x3850c7bd",
  balanceOf: "0x70a08231",
};

var TOPIC_BOUGHT = "0x27330bd7589580547b6437e08f9c60653de63691d2d2b2c13bff9ee67da2a68d";
var TOPIC_SKIPPED = "0xa182d8dc6bf2a8275b96ebc0b69b98d3b9d4fd70fcf5e636fad2b43c26f52170";

var REACTSCAN_TX = "https://lasna.reactscan.net/tx/";
var BLOCKSCOUT_TX = "https://base-sepolia.blockscout.com/tx/";

var REFRESH_MS = 30000;
var RPC_TIMEOUT_MS = 15000;
var SAFETY_LREACT_WEI = 20000000000000000n; // 0.02 lREACT
var MAX_TAIL_BLOCKS = 200000;

/* ---------- small helpers ---------- */

function $(id) { return document.getElementById(id); }

function shortHash(h) { return h.slice(0, 10) + "…" + h.slice(-6); }

function hexToBigInt(hex) { return BigInt(hex); } // hex strings only, never Number

function decodeWords(hex) {
  var h = hex.slice(2);
  var out = [];
  for (var i = 0; i + 64 <= h.length; i += 64) out.push(BigInt("0x" + h.slice(i, i + 64)));
  return out;
}

/* Format a fixed-point BigInt: value / 10^decimals, with `dp` decimals shown
   (trailing zeros trimmed when trim=true). Integer part gets thousands separators. */
function fmtFixed(value, decimals, dp, trim) {
  var neg = value < 0n;
  var v = neg ? -value : value;
  var scale = 10n ** BigInt(decimals);
  var whole = v / scale;
  var frac = v % scale;
  var fracStr = frac.toString().padStart(decimals, "0").slice(0, dp);
  if (trim) fracStr = fracStr.replace(/0+$/, "");
  var wholeStr = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  var out = fracStr.length ? wholeStr + "." + fracStr : wholeStr;
  return neg ? "-" + out : out;
}

function fmtUsd6(value) { return "$" + fmtFixed(value, 6, 2, false); }
function fmtLreact(value) { return fmtFixed(value, 18, 7, true); }
function fmtWeth(value) { return fmtFixed(value, 18, 18, true); }
function fmtUsdc(value) { return fmtFixed(value, 6, 6, true); }

/* Format an exact decimal STRING as dollars with 2 decimals (truncated, never
   rounded up) and thousands separators — no Number() involved, so large
   values cannot lose precision. */
function fmtUsdStr(s) {
  var parts = String(s).split(".");
  var whole = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  var frac = (parts[1] || "").padEnd(2, "0").slice(0, 2);
  return "$" + whole + "." + frac;
}

function fmtAmountStr(s) {
  var parts = String(s).split(".");
  var frac = (parts[1] || "").padEnd(2, "0").slice(0, 2);
  return parts[0] + "." + frac;
}

/* Escape dynamic text before it goes into innerHTML (defense in depth: the
   data comes from our own buys.json and public RPC log responses, neither of
   which is user input, but a compromised RPC must not become script). */
function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function setStatus(el, msg, isError) {
  el.textContent = msg;
  el.classList.toggle("error", !!isError);
}

function nowTime() {
  return new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

/* ---------- RPC ---------- */

function rpc(url, method, params) {
  var controller = new AbortController();
  var timer = setTimeout(function () { controller.abort(); }, RPC_TIMEOUT_MS);
  return fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: method, params: params }),
    signal: controller.signal,
  })
    .then(function (res) {
      clearTimeout(timer);
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.json();
    })
    .then(function (json) {
      if (json.error) throw new Error(json.error.message || "RPC error");
      return json.result;
    })
    .catch(function (err) {
      clearTimeout(timer);
      throw err;
    });
}

/* Try each URL in order; return the first success, else throw the last error. */
function rpcFirst(urls, method, params) {
  var lastErr = null;
  var chain = Promise.reject();
  urls.forEach(function (url) {
    chain = chain.catch(function () {
      return rpc(url, method, params).catch(function (err) { lastErr = err; throw err; });
    });
  });
  return chain.catch(function () { throw lastErr || new Error("all RPCs failed"); });
}

function ethCall(urls, to, data) {
  return rpcFirst(urls, "eth_call", [{ to: to, data: data }, "latest"]);
}

function ethBalance(urls, address) {
  return rpcFirst(urls, "eth_getBalance", [address, "latest"]);
}

function blockNumber(urls) {
  return rpcFirst(urls, "eth_blockNumber", []);
}

function balanceOfCalldata(address) {
  return SEL.balanceOf + "000000000000000000000000" + address.slice(2).toLowerCase();
}

/* Chunked eth_getLogs with per-chunk RPC fallback: chunks are fetched
   sequentially from the primary RPC; a failed chunk is retried on the next
   RPC (with that RPC's smaller chunk size) from the same block — the scan
   resumes, it never restarts from the beginning. Once the scan falls back
   it stays on the fallback RPC for the rest of the range. */
function getLogsChunked(address, topic, fromBlock, toBlock) {
  var logs = [];
  function scan(rpcIndex, from) {
    if (from > toBlock) return Promise.resolve(logs);
    var chunk = BASE_CHUNK[rpcIndex];
    var to = Math.min(from + chunk - 1, toBlock);
    return rpc(BASE_RPCS[rpcIndex], "eth_getLogs", [{
      fromBlock: "0x" + from.toString(16),
      toBlock: "0x" + to.toString(16),
      address: address,
      topics: [topic],
    }]).then(function (res) {
      logs.push.apply(logs, res);
      return scan(rpcIndex, to + 1);
    }).catch(function () {
      if (rpcIndex + 1 < BASE_RPCS.length) return scan(rpcIndex + 1, from);
      throw new Error("eth_getLogs failed on all RPCs");
    });
  }
  return scan(0, fromBlock);
}

/* ---------- price math (same two-step form as PriceMath.sol) ---------- */

/* price6 = (2^192 / sqrtP) * 10^18 / sqrtP — never squares sqrtP, matches the
   contract to at most 1 ulp (1e-6 USDC). */
function priceFromSqrt(sqrtP) {
  if (sqrtP === 0n) return 0n;
  var a = (2n ** 192n) / sqrtP;
  return (a * 10n ** 18n) / sqrtP;
}

/* ---------- state ---------- */

var state = {
  lasnaOk: false,
  baseOk: false,
  staticBuys: [],
  staticSkipped: 0,
  lastIndexedBlockBase: 0,
  lastScannedBlockBase: 0,
  tailBuys: [],
  tailSkipped: 0,
  tailNote: "",
};

function renderStatus(rule, debt) {
  var interval = rule[2];
  var parked = interval >= 100000n;
  var parkedText = parked
    ? "Parked — interval " + interval.toLocaleString("en-US") + " ticks"
    : "Running — interval " + interval.toLocaleString("en-US") + " tick" + (interval === 1n ? "" : "s");
  $("status-parked-text").textContent = parkedText;
  $("status-parked").className = "chip " + (parked ? "chip-parked" : "chip-ok");

  var hasDebt = debt > 0n;
  $("status-debt").hidden = !hasDebt;
  $("status-ready").hidden = !(parked && !hasDebt);
  if (hasDebt) {
    $("status-debt-text").textContent = "Debt stall — " + fmtLreact(debt) + " lREACT owed";
    $("status-debt").title = "Reactive debt " + fmtLreact(debt) + " lREACT — callbacks suspended until repaid via coverDebt().";
    $("debt-banner-text").textContent =
      "Loop suspended — reactive debt " + fmtLreact(debt) + " lREACT exceeds balance.";
    $("debt-banner-sub").textContent =
      "Callbacks stay suspended until the owner tops up the reactive and repays the debt.";
    $("debt-banner").hidden = false;
  } else {
    $("debt-banner").hidden = true;
  }
}

/* Failure handling: a failed read must not leave the previous values on
   screen looking live. Clear the affected figures to "—" and reset the
   status chips — the status line below each section says what failed. */
function clearFigures(ids) {
  ids.forEach(function (id) { $(id).textContent = "—"; });
}

function failLasna(msg) {
  state.lasnaOk = false;
  setStatus($("health-status"), msg, true);
  setStatus($("rule-status"), msg, true);
  clearFigures(["health-balance", "health-debt", "health-guard", "cb-requested",
    "price-last", "price-ema", "price-ref", "price-thresholds",
    "rule-amount", "rule-interval", "rule-max", "rule-guard", "rule-resume",
    "rule-paused", "rule-ticks", "rule-lastbuy"]);
  $("health-debt-sub").textContent = "lREACT · Lasna";
  $("health-guard-sub").textContent = "Trips on a sharp drop, resumes on recovery";
  $("health-guard").style.color = "";
  $("health-balance").parentElement.classList.remove("figure-alert");
  $("health-balance").parentElement.querySelector(".figure-sub").textContent = "lREACT · Lasna";
  $("status-parked-text").textContent = "Status unknown — Lasna unreachable";
  $("status-parked").className = "chip chip-parked";
  $("status-debt").hidden = true;
  $("status-ready").hidden = true;
  $("debt-banner").hidden = true;
}

function failBase(msg) {
  state.baseOk = false;
  setStatus($("vault-status"), msg, true);
  clearFigures(["health-vault-debt", "cb-filled", "vault-usdc", "vault-weth",
    "vault-spent", "vault-bought", "price-pool"]);
}

function loadLasna() {
  var urls = [LASNA_RPC];
  var calls = {
    rule: ethCall(urls, REACTIVE, SEL.rule),
    lastPrice: ethCall(urls, REACTIVE, SEL.lastPrice),
    emaPrice: ethCall(urls, REACTIVE, SEL.emaPrice),
    referencePrice: ethCall(urls, REACTIVE, SEL.referencePrice),
    guardTripped: ethCall(urls, REACTIVE, SEL.guardTripped),
    tickCount: ethCall(urls, REACTIVE, SEL.tickCount),
    lastBuyTick: ethCall(urls, REACTIVE, SEL.lastBuyTick),
    buyRequests: ethCall(urls, REACTIVE, SEL.buyRequests),
    debt: ethCall(urls, REACTIVE, SEL.debt),
    balance: ethBalance(urls, REACTIVE),
  };
  var keys = Object.keys(calls);
  return Promise.allSettled(keys.map(function (k) { return calls[k]; })).then(function (results) {
    var v = {};
    var failed = [];
    results.forEach(function (r, i) {
      if (r.status === "fulfilled") v[keys[i]] = r.value;
      else failed.push(keys[i]);
    });
    if (failed.length !== 0) {
      failLasna("Lasna RPC unreachable (" + failed.join(", ") + " failed) — see Reactscan for the reactive contract.");
      return;
    }
    try {
      var rule = decodeWords(v.rule); // amountIn, maxPrice, intervalTicks, guardBps, resumeBps, paused
      if (rule.length < 6) throw new Error("rule() returned " + rule.length + " words, expected 6");
      renderLasna(v, rule);
    } catch (err) {
      failLasna("Lasna response malformed (" + err.message + ") — see Reactscan for the reactive contract.");
    }
  });
}

function renderLasna(v, rule) {
    state.lasnaOk = true;
    setStatus($("health-status"), "Lasna reads ok · updated " + nowTime());
    setStatus($("rule-status"), "Lasna reads ok · updated " + nowTime());

    var debt = hexToBigInt(v.debt);
    var balance = hexToBigInt(v.balance);
    var lastPrice = hexToBigInt(v.lastPrice);
    var emaPrice = hexToBigInt(v.emaPrice);
    var reference = hexToBigInt(v.referencePrice);
    var guardTripped = hexToBigInt(v.guardTripped) !== 0n;
    var tickCount = hexToBigInt(v.tickCount);
    var lastBuyTick = hexToBigInt(v.lastBuyTick);
    var buyRequests = hexToBigInt(v.buyRequests);

    renderStatus(rule, debt);

    /* health */
    $("health-balance").textContent = fmtLreact(balance);
    $("health-debt").textContent = fmtLreact(debt);
    $("health-debt-sub").textContent = debt > 0n
      ? "lREACT · Lasna — loop suspended until repaid"
      : "lREACT · Lasna — no debt";
    $("health-balance").parentElement.classList.toggle("figure-alert", balance < SAFETY_LREACT_WEI);
    $("health-balance").parentElement.querySelector(".figure-sub").textContent =
      balance < SAFETY_LREACT_WEI
        ? "lREACT · Lasna — below the 0.02 safety line"
        : "lREACT · Lasna";
    $("health-guard").textContent = guardTripped ? "Tripped" : "Clear";
    $("health-guard").style.color = guardTripped ? "var(--red)" : "var(--green-dark)";
    $("health-guard-sub").textContent = guardTripped
      ? "Vault paused — buying stopped by the guard"
      : "Trips on a sharp drop, resumes on recovery";

    /* callbacks: requested count from state */
    $("cb-requested").textContent = buyRequests.toString();

    /* price panel: reactive-side figures */
    $("price-last").textContent = fmtUsd6(lastPrice);
    $("price-ema").textContent = fmtUsd6(emaPrice);
    $("price-ref").textContent = fmtUsd6(reference);
    var trip = (reference * (10000n + rule[3])) / 10000n;
    var resume = (reference * (10000n + rule[4])) / 10000n;
    $("price-thresholds").textContent =
      "Trip above " + fmtUsd6(trip) + " · Resume below " + fmtUsd6(resume);
    $("price-thresholds-sub").textContent =
      "Guard " + fmtFixed(rule[3], 2, 2, true) + "% · resume " + fmtFixed(rule[4], 2, 2, true) + "% vs reference";

    /* rule panel */
    $("rule-amount").textContent = fmtUsdc(rule[0]) + " USDC";
    $("rule-interval").textContent = rule[2].toLocaleString("en-US") + " ticks";
    $("rule-max").textContent = fmtUsd6(rule[1]);
    $("rule-guard").textContent = fmtFixed(rule[3], 2, 2, true) + "% below reference";
    $("rule-resume").textContent = fmtFixed(rule[4], 2, 2, true) + "% below reference";
    $("rule-paused").textContent = rule[5] !== 0n ? "Yes" : "No";
    $("rule-ticks").textContent = tickCount.toString();
    $("rule-lastbuy").textContent = lastBuyTick.toString();
}

function loadBase() {
  var calls = {
    paused: ethCall(BASE_RPCS, VAULT, SEL.paused),
    buyCount: ethCall(BASE_RPCS, VAULT, SEL.buyCount),
    totalUsdcSpent: ethCall(BASE_RPCS, VAULT, SEL.totalUsdcSpent),
    totalWethBought: ethCall(BASE_RPCS, VAULT, SEL.totalWethBought),
    debt: ethCall(BASE_RPCS, VAULT, SEL.debt),
    slot0: ethCall(BASE_RPCS, POOL, SEL.slot0),
    usdcBal: ethCall(BASE_RPCS, USDC, balanceOfCalldata(VAULT)),
    wethBal: ethCall(BASE_RPCS, WETH, balanceOfCalldata(VAULT)),
  };
  var keys = Object.keys(calls);
  return Promise.allSettled(keys.map(function (k) { return calls[k]; })).then(function (results) {
    var v = {};
    var failed = [];
    results.forEach(function (r, i) {
      if (r.status === "fulfilled") v[keys[i]] = r.value;
      else failed.push(keys[i]);
    });
    if (failed.length !== 0) {
      failBase("Base Sepolia RPCs unreachable (" + failed.join(", ") + " failed) — try Blockscout for the vault.");
      return;
    }
    try {
      var slot0 = decodeWords(v.slot0);
      if (slot0.length < 1) throw new Error("slot0() returned no words");
      renderBase(v, slot0[0]);
    } catch (err) {
      failBase("Base Sepolia response malformed (" + err.message + ") — try Blockscout for the vault.");
    }
  });
}

function renderBase(v, sqrtP) {
    state.baseOk = true;
    setStatus($("vault-status"), "Base Sepolia reads ok · updated " + nowTime());

    var vaultDebt = hexToBigInt(v.debt);
    var buyCount = hexToBigInt(v.buyCount);
    $("health-vault-debt").textContent = vaultDebt === 0n ? "0" : fmtFixed(vaultDebt, 18, 7, true);
    $("cb-filled").textContent = buyCount.toString();
    $("vault-usdc").textContent = fmtUsdc(hexToBigInt(v.usdcBal));
    $("vault-weth").textContent = fmtWeth(hexToBigInt(v.wethBal));
    $("vault-spent").textContent = fmtUsdc(hexToBigInt(v.totalUsdcSpent)) + " USDC";
    $("vault-bought").textContent = fmtWeth(hexToBigInt(v.totalWethBought)) + " WETH";

    $("price-pool").textContent = fmtUsd6(priceFromSqrt(sqrtP));
}

/* ---------- history: pre-indexed buys + live tail scan ---------- */

function renderLedger() {
  var all = state.staticBuys.concat(state.tailBuys);
  var body = $("ledger-body");
  if (!all.length) {
    body.innerHTML = '<tr><td colspan="7" class="loading-cell mono">No buys found yet.</td></tr>';
    return;
  }
  body.innerHTML = all.map(function (b) {
    /* Tail buys have no Lasna request tx yet — show a dash, not a broken link. */
    var lasnaCell = b.txLasna
      ? "<a href=\"" + escapeHtml(REACTSCAN_TX + b.txLasna) + "\">" + escapeHtml(shortHash(b.txLasna)) + "</a>"
      : "<span class=\"mono\" style=\"color:var(--ink-muted)\">—</span>";
    return "<tr>" +
      "<td class=\"mono\">" + escapeHtml(b.n) + "</td>" +
      "<td><a href=\"" + escapeHtml(BLOCKSCOUT_TX + b.txBase) + "\">" + escapeHtml(shortHash(b.txBase)) + "</a></td>" +
      "<td>" + lasnaCell + "</td>" +
      "<td class=\"num\">" + escapeHtml(fmtAmountStr(b.amountInUsdc)) + "</td>" +
      "<td class=\"num\">" + escapeHtml(b.amountOutWeth) + "</td>" +
      "<td class=\"num\">" + escapeHtml(fmtUsdStr(b.priceUsd)) + "</td>" +
      "<td class=\"num\">" + escapeHtml(b.blockBase.toLocaleString("en-US")) + "</td>" +
      "</tr>";
  }).join("");
}

function loadStaticHistory() {
  return fetch("data/buys.json")
    .then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.json();
    })
    .then(function (data) {
      /* buys.json stores amounts as exact decimal strings — use them as-is. */
      state.staticBuys = data.buys;
      state.staticSkipped = data.buySkippedCount || 0;
      state.lastIndexedBlockBase = data.lastIndexedBlockBase;
      $("cb-skipped").textContent = String(state.staticSkipped + state.tailSkipped);
      renderLedger();
      setStatus($("ledger-status"),
        "History pre-indexed from on-chain events through block " +
        state.lastIndexedBlockBase.toLocaleString("en-US") + " · live tail scan follows.");
    })
    .catch(function (err) {
      $("ledger-body").innerHTML = '<tr><td colspan="7" class="loading-cell mono">History unavailable — see the vault events on Blockscout.</td></tr>';
      setStatus($("ledger-status"), "History file unavailable (" + err.message + ") — see the vault events on Blockscout.", true);
    });
}

/* Tail-scan cursor: each refresh scans only blocks newer than the last
   successful scan, instead of re-scanning the whole range from the indexed
   history every 30s. The cursor is kept in memory and in sessionStorage
   (guarded — storage may be unavailable), so a page reload resumes where
   the last scan left off instead of re-fetching everything. */
var TAIL_CURSOR_KEY = "steadystack-tail-head";

function loadCursor() {
  try {
    if (typeof window === "undefined" || !window.sessionStorage) return 0;
    var n = parseInt(window.sessionStorage.getItem(TAIL_CURSOR_KEY), 10);
    return n > 0 ? n : 0;
  } catch (e) { return 0; }
}

function saveCursor(block) {
  try {
    if (typeof window !== "undefined" && window.sessionStorage) {
      window.sessionStorage.setItem(TAIL_CURSOR_KEY, String(block));
    }
  } catch (e) { /* storage unavailable — the in-memory cursor still works */ }
}

function scanTail() {
  if (!state.lastIndexedBlockBase) return Promise.resolve();
  return blockNumber(BASE_RPCS).then(function (latestHex) {
    var latest = Number(BigInt(latestHex)); // block numbers are far below 2^53
    var head = Math.max(state.lastIndexedBlockBase, state.lastScannedBlockBase || 0, loadCursor());
    var from = head + 1;
    if (latest < from) {
      setStatus($("ledger-status"), "History current through block " + latest.toLocaleString("en-US") + ".");
      return;
    }
    var capped = latest - from + 1 > MAX_TAIL_BLOCKS;
    if (capped) from = latest - MAX_TAIL_BLOCKS + 1;
    /* allSettled: a failed BuySkipped scan must not discard the Bought logs. */
    return Promise.allSettled([
      getLogsChunked(VAULT, TOPIC_BOUGHT, from, latest),
      getLogsChunked(VAULT, TOPIC_SKIPPED, from, latest),
    ]).then(function (pair) {
      var boughtOk = pair[0].status === "fulfilled";
      var skippedOk = pair[1].status === "fulfilled";
      if (boughtOk) {
        var boughtLogs = pair[0].value;
        var seen = {};
        state.staticBuys.forEach(function (b) { seen[b.txBase.toLowerCase()] = true; });
        state.tailBuys.forEach(function (b) { seen[b.txBase.toLowerCase()] = true; });
        var nextN = state.staticBuys.length + state.tailBuys.length + 1;
        boughtLogs.forEach(function (log) {
          if (seen[log.transactionHash.toLowerCase()]) return;
          seen[log.transactionHash.toLowerCase()] = true;
          var w = decodeWords(log.data); // amountIn, amountOut, price, blockNumber
          if (w.length < 4) return; // malformed log — skip it, don't crash the scan
          state.tailBuys.push({
            n: nextN++,
            txBase: log.transactionHash,
            blockBase: Number(BigInt(log.blockNumber)),
            txLasna: "",
            blockLasna: 0,
            tick: 0,
            /* Exact decimal strings, like buys.json — no Number() on money. */
            amountInUsdc: fmtUsdc(w[0]),
            amountOutWeth: fmtWeth(w[1]),
            priceUsd: fmtFixed(w[2], 6, 6, true),
          });
        });
        /* Advance the cursor only on a successful Bought scan. */
        state.lastScannedBlockBase = latest;
        saveCursor(latest);
      }
      if (skippedOk) {
        /* The cursor makes each scan cover only new blocks, so accumulate. */
        state.tailSkipped += pair[1].value.length;
        $("cb-skipped").textContent = String(state.staticSkipped + state.tailSkipped);
      }
      renderLedger();
      var note = "History current through block " + latest.toLocaleString("en-US") +
        (state.tailBuys.length ? " · " + state.tailBuys.length + " new buy(s) found live." : " · no new buys.") +
        (capped ? " (tail scan capped at " + MAX_TAIL_BLOCKS.toLocaleString("en-US") + " blocks)" : "") +
        (!boughtOk ? " (Bought scan failed — ledger may miss the newest buys)" : "") +
        (!skippedOk ? " (skipped count may be stale)" : "");
      setStatus($("ledger-status"), note, !boughtOk || !skippedOk);
    });
  }).catch(function (err) {
    setStatus($("ledger-status"),
      "Live tail scan unavailable (" + err.message + ") — showing indexed history only.", true);
  });
}

/* ---------- refresh loop ---------- */

/* Skip a tick while a refresh is still in flight — a slow RPC must not let
   two refreshes overlap and fight over the same DOM nodes. Cycles are
   strictly serialized: a new cycle cannot start while one is running, so a
   stale cycle can never overwrite fresher data. */
var refreshInFlight = false;

/* Returns a promise of true (all reads ok), false (some read failed), or
   null (skipped — a refresh was already in flight). */
function refreshAll() {
  if (refreshInFlight) return Promise.resolve(null);
  refreshInFlight = true;
  return Promise.all([loadLasna(), loadBase(), scanTail()]).then(function () {
    refreshInFlight = false;
    var ok = state.lasnaOk && state.baseOk;
    /* Price section depends on BOTH chains — decide its status line here,
       after both loaders have settled, not inside either loader. */
    if (ok) setStatus($("price-status"), "Price reads ok · updated " + nowTime());
    else if (!state.lasnaOk && !state.baseOk) setStatus($("price-status"), "Price reads unavailable — both RPCs unreachable.", true);
    else if (!state.lasnaOk) setStatus($("price-status"), "Reactive price reads unavailable — pool price above is live.", true);
    else setStatus($("price-status"), "Pool price unavailable — reactive figures above are live.", true);
    $("updated-top").textContent = ok
      ? "Updated " + nowTime() + " · refreshes every 30s"
      : "Updated " + nowTime() + " · some reads failed, retrying";
    $("live-indicator").classList.toggle("stale", !ok);
    $("live-label").textContent = ok ? "Live" : "Partial";
    $("page-status").textContent =
      "Data sources: Lasna " + LASNA_RPC + " · Base Sepolia " +
      BASE_RPCS.join(" / ") + " · last refresh " + nowTime();
    return ok;
  }).catch(function () {
    /* Never leave the guard set: a failed refresh must not stop later ticks. */
    refreshInFlight = false;
    return false;
  });
}

/* Jittered refresh with exponential backoff: the ±30% jitter desynchronizes
   concurrent visitors (no thundering herd on the public RPCs), and backoff
   stops hammering a failing RPC — the next attempt waits up to 5 minutes. */
var refreshBackoff = 0;

function scheduleRefresh() {
  var delay = REFRESH_MS + Math.random() * REFRESH_MS * 0.3;
  if (refreshBackoff > 0) delay = Math.min(delay * Math.pow(2, refreshBackoff), 5 * 60 * 1000);
  setTimeout(function () {
    refreshAll().then(function (ok) {
      if (ok === true) refreshBackoff = 0;
      else if (ok === false) refreshBackoff = Math.min(refreshBackoff + 1, 6);
      scheduleRefresh();
    });
  }, delay);
}

/* ---------- copy buttons ---------- */

document.querySelectorAll(".copy-btn").forEach(function (btn) {
  btn.addEventListener("click", function () {
    var text = btn.getAttribute("data-copy");
    function done() {
      var old = btn.textContent;
      btn.textContent = "Copied";
      setTimeout(function () { btn.textContent = old; }, 1500);
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () { fallbackCopy(text); done(); });
    } else {
      fallbackCopy(text);
      done();
    }
  });
});

function fallbackCopy(text) {
  var ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  try { document.execCommand("copy"); } catch (e) { /* clipboard unavailable */ }
  document.body.removeChild(ta);
}

/* ---------- init ---------- */

/* Browsers throttle timers in background tabs — refresh immediately when the
   tab becomes visible again instead of showing silently stale data. */
if (typeof document !== "undefined" && document.addEventListener) {
  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) refreshAll();
  });
}

loadStaticHistory().then(function () {
  return refreshAll().then(function (ok) {
    if (ok === false) refreshBackoff = 1;
    scheduleRefresh();
  });
});
