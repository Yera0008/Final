import { useState, useEffect } from "react";
import { ethers } from "ethers";

// ── Contract addresses (Arbitrum Sepolia) ────────────────────────────────────
const ADDRESSES = {
  market:      "0x8bE287Cddb210165a7F47Fc84a04Ccc26E9a335A",
  govToken:    "0x2d041dec8fD1f50741B3B08721be1077680e15AB",
  usdc:        "0xb29e8CdF93058d65ecD784753BD23a9B7C3F9a74",
  outcomeToken:"0x286bB5A85Baa67A17A7F5379d09C0562425DF462",
  governor:    "0x6d221157AE69fA5e7516fcfd513d3e37cE335cAe",
  feeVault:    "0x2213868317b468b0c058D3Ef70c078B88eC6e7D8",
  oracle:      "0x46F89e2315f0095bB7A19DE06774aD42372aB23C",
  timelock:    "0x2482f087466d97D0a70b87153888AD6760e417f2",
  factory:     "0xeAd8FD78471c703cfbcb645D3c9bc5Cf41C6E6b5",
};
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1753417/final/v0.0.1";

const ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

// ── Minimal ABIs ─────────────────────────────────────────────────────────────
const MARKET_ABI = [
  "function createMarket(string,address,int256,uint256,uint256,uint256) returns (uint256)",
  "function buyOutcome(uint256,bool,uint256,uint256) external",
  "function addLiquidity(uint256,uint256,uint256) external",
  "function removeLiquidity(uint256,uint256) external",
  "function resolveMarket(uint256) external",
  "function finalizeResolution(uint256) external",
  "function redeem(uint256) external",
  "function getMarketState(uint256) view returns (uint8)",
  "function getMarketOutcome(uint256) view returns (uint8)",
  "function getMarketQuestion(uint256) view returns (string)",
  "function getPoolReserves(uint256) view returns (uint256,uint256)",
  "function marketCount() view returns (uint256)",
  "function lpShares(address,uint256) view returns (uint256)",
];

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address,uint256) external",
  "function decimals() view returns (uint8)",
  "function getVotes(address) view returns (uint256)",
  "function delegates(address) view returns (address)",
  "function delegate(address) external",
];

const ERC1155_ABI = [
  "function balanceOf(address,uint256) view returns (uint256)",
];

const GOVERNOR_ABI = [
  "function propose(address[],uint256[],bytes[],string) returns (uint256)",
  "function castVote(uint256,uint8) external",
  "function queue(address[],uint256[],bytes[],bytes32) external",
  "function execute(address[],uint256[],bytes[],bytes32) external",
  "function state(uint256) view returns (uint8)",
  "function proposalVotes(uint256) view returns (uint256,uint256,uint256)",
];

const STATE_LABELS = ["Open","PendingResolution","Resolved","Disputed","Cancelled"];
const OUTCOME_LABELS = ["Unresolved","YES","NO"];
const PROPOSAL_STATES = ["Pending","Active","Canceled","Defeated","Succeeded","Queued","Expired","Executed"];

// ── Subgraph query ────────────────────────────────────────────────────────────
const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/YOUR_ID/prediction-market/v0.0.1";

async function fetchMarketsFromSubgraph() {
  try {
    const res = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: `{ markets(orderBy: createdAt, orderDirection: desc, first: 10) {
          id question state outcome totalCollateral createdAt
        }}`
      })
    });
    const json = await res.json();
    return json?.data?.markets || [];
  } catch { return []; }
}

// ── Main App ──────────────────────────────────────────────────────────────────
export default function App() {
  const [provider, setProvider]     = useState(null);
  const [signer, setSigner]         = useState(null);
  const [account, setAccount]       = useState(null);
  const [chainId, setChainId]       = useState(null);
  const [tab, setTab]               = useState("markets");
  const [markets, setMarkets]       = useState([]);
  const [subgraphMarkets, setSubgraphMarkets] = useState([]);
  const [loading, setLoading]       = useState(false);
  const [txStatus, setTxStatus]     = useState("");
  const [usdcBalance, setUsdcBalance] = useState("0");
  const [govBalance, setGovBalance]   = useState("0");
  const [votingPower, setVotingPower] = useState("0");
  const [delegateAddr, setDelegateAddr] = useState("");

  // Form states
  const [buyMarketId, setBuyMarketId] = useState("1");
  const [buyIsYes, setBuyIsYes]       = useState(true);
  const [buyAmount, setBuyAmount]     = useState("10");
  const [createQuestion, setCreateQuestion] = useState("");
  const [createResTime, setCreateResTime]   = useState("");
  const [createInitYes, setCreateInitYes]   = useState("1000");
  const [createInitNo, setCreateInitNo]     = useState("1000");
  const [propDesc, setPropDesc]       = useState("");
  const [voteProposalId, setVoteProposalId] = useState("");
  const [voteSupport, setVoteSupport]       = useState("1");

  // ── Connect Wallet ──────────────────────────────────────────────────────────
  async function connectWallet() {
    if (!window.ethereum) { setTxStatus("❌ MetaMask not found"); return; }
    try {
      const prov = new ethers.BrowserProvider(window.ethereum);
      const network = await prov.getNetwork();
      setChainId(Number(network.chainId));

      if (Number(network.chainId) !== ARBITRUM_SEPOLIA_CHAIN_ID) {
        setTxStatus("⚠️ Wrong network! Switching to Arbitrum Sepolia...");
        try {
          await window.ethereum.request({
            method: "wallet_switchEthereumChain",
            params: [{ chainId: "0x66eee" }],
          });
        } catch {
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: "0x66eee",
              chainName: "Arbitrum Sepolia",
              rpcUrls: ["https://sepolia-rollup.arbitrum.io/rpc"],
              nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
              blockExplorerUrls: ["https://sepolia.arbiscan.io"],
            }],
          });
        }
        return;
      }

      const sig = await prov.getSigner();
      const addr = await sig.getAddress();
      setProvider(prov); setSigner(sig); setAccount(addr);
      setTxStatus("✅ Connected: " + addr.slice(0,6) + "..." + addr.slice(-4));
      await loadBalances(prov, sig, addr);
      await loadMarkets(prov);
    } catch (e) { setTxStatus("❌ " + e.message); }
  }

  async function loadBalances(prov, sig, addr) {
    try {
      const usdc = new ethers.Contract(ADDRESSES.usdc, ERC20_ABI, prov);
      const gov  = new ethers.Contract(ADDRESSES.govToken, ERC20_ABI, prov);
      const ub = await usdc.balanceOf(addr);
      const gb = await gov.balanceOf(addr);
      const vp = await gov.getVotes(addr);
      const dl = await gov.delegates(addr);
      setUsdcBalance(ethers.formatUnits(ub, 6));
      setGovBalance(ethers.formatUnits(gb, 18));
      setVotingPower(ethers.formatUnits(vp, 18));
      setDelegateAddr(dl);
    } catch {}
  }

  async function loadMarkets(prov) {
    try {
      const mc = new ethers.Contract(ADDRESSES.market, MARKET_ABI, prov);
      const count = Number(await mc.marketCount());
      const list = [];
      for (let i = 1; i <= count; i++) {
        const [state, outcome, question, [yes, no]] = await Promise.all([
          mc.getMarketState(i),
          mc.getMarketOutcome(i),
          mc.getMarketQuestion(i),
          mc.getPoolReserves(i),
        ]);
        list.push({ id: i, state: Number(state), outcome: Number(outcome),
          question, yes: ethers.formatUnits(yes, 6), no: ethers.formatUnits(no, 6) });
      }
      setMarkets(list);
    } catch {}
    // also fetch from subgraph
    const sg = await fetchMarketsFromSubgraph();
    setSubgraphMarkets(sg);
  }

  // ── Transactions ────────────────────────────────────────────────────────────
  async function approveUSDC(amount) {
  const usdc = new ethers.Contract(ADDRESSES.usdc, ERC20_ABI, signer);
  const feeData = await provider.getFeeData();
  const tx = await usdc.approve(ADDRESSES.market, ethers.parseUnits(amount, 6), {
    maxFeePerGas: feeData.maxFeePerGas * 2n,
    maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
  });
  await tx.wait();
}

  async function handleBuy() {
  if (!signer) { setTxStatus("Connect wallet first"); return; }
  setLoading(true); setTxStatus("Approving USDC...");
  try {
    await approveUSDC(buyAmount);
    setTxStatus("⏳ Buying outcome...");
    const mc = new ethers.Contract(ADDRESSES.market, MARKET_ABI, signer);
    const feeData = await provider.getFeeData();
    const tx = await mc.buyOutcome(
      buyMarketId, buyIsYes,
      ethers.parseUnits(buyAmount, 6), 0,
      {
        maxFeePerGas: feeData.maxFeePerGas * 2n,
        maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
      }
    );
    await tx.wait();
    setTxStatus(`✅ Bought ${buyIsYes ? "YES" : "NO"} tokens! TX: ${tx.hash.slice(0,10)}...`);
    await loadMarkets(provider);
    await loadBalances(provider, signer, account);
  } catch (e) { setTxStatus("❌ " + (e.reason || e.message)); }
  setLoading(false);
}

  async function handleCreateMarket() {
    if (!signer) { setTxStatus("❌ Connect wallet first"); return; }
    setLoading(true); setTxStatus("⏳ Approving USDC...");
    try {
      const total = Number(createInitYes) + Number(createInitNo);
      await approveUSDC(String(total));
      setTxStatus("⏳ Creating market...");
      const mc = new ethers.Contract(ADDRESSES.market, MARKET_ABI, signer);
      // Use mock oracle feed address
      const MOCK_FEED = "0x0000000000000000000000000000000000000001";
      const resTime = Math.floor(new Date(createResTime).getTime() / 1000);
const feeData = await provider.getFeeData();
const tx = await mc.createMarket(
  createQuestion, MOCK_FEED, 3000_00000000n, resTime,
  ethers.parseUnits(createInitYes, 6),
  ethers.parseUnits(createInitNo, 6),
  {
    maxFeePerGas: feeData.maxFeePerGas * 2n,
    maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
  }
);
      await tx.wait();
      setTxStatus("✅ Market created! TX: " + tx.hash.slice(0,10) + "...");
      await loadMarkets(provider);
    } catch (e) { setTxStatus("❌ " + (e.reason || e.message)); }
    setLoading(false);
  }

  async function handleDelegate() {
  if (!signer) { setTxStatus("Connect wallet first"); return; }
  setLoading(true); setTxStatus("Delegating votes...");
  try {
    const gov = new ethers.Contract(ADDRESSES.govToken, ERC20_ABI, signer);
    const feeData = await provider.getFeeData();
    const tx = await gov.delegate(account, {
      maxFeePerGas: feeData.maxFeePerGas * 2n,
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
    });
    await tx.wait();
    setTxStatus("Delegated to self!");
    await loadBalances(provider, signer, account);
  } catch (e) { setTxStatus((e.reason || e.message)); }
  setLoading(false);
}


  async function handlePropose() {
  if (!signer) { setTxStatus("Connect wallet first"); return; }
  setLoading(true); setTxStatus("Submitting proposal...");
  try {
    const gov = new ethers.Contract(ADDRESSES.governor, GOVERNOR_ABI, signer);
    const feeData = await provider.getFeeData();
    const tx = await gov.propose([ADDRESSES.market], [0], ["0x"], propDesc, {
      maxFeePerGas: feeData.maxFeePerGas * 2n,
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
    });
    await tx.wait();
    setTxStatus("Proposal submitted! TX: " + tx.hash.slice(0,10) + "...");
  } catch (e) { setTxStatus((e.reason || e.message)); }
  setLoading(false);
}

  async function handleVote() {
  if (!signer) { setTxStatus("Connect wallet first"); return; }
  setLoading(true); setTxStatus("Casting vote...");
  try {
    const gov = new ethers.Contract(ADDRESSES.governor, GOVERNOR_ABI, signer);
    const feeData = await provider.getFeeData();
    const tx = await gov.castVote(voteProposalId, Number(voteSupport), {
      maxFeePerGas: feeData.maxFeePerGas * 2n,
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
    });
    await tx.wait();
    setTxStatus("Vote cast!");
  } catch (e) { setTxStatus((e.reason || e.message)); }
  setLoading(false);
}

  async function handleRedeem(marketId) {
  if (!signer) { setTxStatus("Connect wallet first"); return; }
  setLoading(true); setTxStatus("Redeeming...");
  try {
    const mc = new ethers.Contract(ADDRESSES.market, MARKET_ABI, signer);
    const feeData = await provider.getFeeData();
    const tx = await mc.redeem(marketId, {
      maxFeePerGas: feeData.maxFeePerGas * 2n,
      maxPriorityFeePerGas: feeData.maxPriorityFeePerGas * 2n,
    });
    await tx.wait();
    setTxStatus("Redeemed!");
    await loadBalances(provider, signer, account);
  } catch (e) { setTxStatus((e.reason || e.message)); }
  setLoading(false);
}

  const wrongNetwork = chainId && chainId !== ARBITRUM_SEPOLIA_CHAIN_ID;

  return (
    <div style={styles.app}>
      <div style={styles.noise} />

      {/* Header */}
      <header style={styles.header}>
        <div style={styles.logo}>
          <span style={styles.logoIcon}>◈</span>
          <span style={styles.logoText}>PREDICT</span>
          <span style={styles.logoSub}>PROTOCOL</span>
        </div>
        <div style={styles.headerRight}>
          {account && (
            <div style={styles.balances}>
              <span style={styles.badge}>{Number(usdcBalance).toFixed(2)} USDC</span>
              <span style={styles.badge}>{Number(govBalance).toFixed(0)} PRED</span>
              <span style={{...styles.badge, background: "rgba(0,255,128,0.15)", color: "#00ff80"}}>
                ⚡ {Number(votingPower).toFixed(0)} VP
              </span>
            </div>
          )}
          <button
            style={account ? styles.btnConnected : styles.btnConnect}
            onClick={connectWallet}
          >
            {account ? `${account.slice(0,6)}...${account.slice(-4)}` : "Connect Wallet"}
          </button>
        </div>
      </header>

      {wrongNetwork && (
        <div style={styles.wrongNetwork}>
          ⚠️ Wrong network — please switch to Arbitrum Sepolia
          <button style={styles.switchBtn} onClick={connectWallet}>Switch Network</button>
        </div>
      )}

      {/* Status bar */}
      {txStatus && (
        <div style={{
          ...styles.statusBar,
          borderColor: txStatus.startsWith("✅") ? "#00ff80" :
                       txStatus.startsWith("❌") ? "#ff4466" : "#ffaa00"
        }}>
          {txStatus}
        </div>
      )}

      {/* Nav */}
      <nav style={styles.nav}>
        {["markets","trade","governance","portfolio"].map(t => (
          <button
            key={t}
            style={tab === t ? styles.navBtnActive : styles.navBtn}
            onClick={() => setTab(t)}
          >
            {t.toUpperCase()}
          </button>
        ))}
      </nav>

      {/* Content */}
      <main style={styles.main}>

        {/* MARKETS TAB */}
        {tab === "markets" && (
          <div>
            <div style={styles.sectionHeader}>
              <h2 style={styles.sectionTitle}>Active Markets</h2>
              <span style={styles.sectionSub}>Live on Arbitrum Sepolia</span>
            </div>

            {markets.length === 0 ? (
              <div style={styles.empty}>
                No markets yet.
                {account && <button style={styles.btnPrimary} onClick={() => setTab("trade")}>Create First Market →</button>}
              </div>
            ) : (
              <div style={styles.grid}>
                {markets.map(m => (
                  <div key={m.id} style={styles.card}>
                    <div style={styles.cardHeader}>
                      <span style={styles.marketId}>#{m.id}</span>
                      <span style={{
                        ...styles.statePill,
                        background: m.state === 0 ? "rgba(0,255,128,0.15)" :
                                    m.state === 2 ? "rgba(0,128,255,0.15)" : "rgba(255,100,0,0.15)",
                        color: m.state === 0 ? "#00ff80" : m.state === 2 ? "#0080ff" : "#ff6400"
                      }}>
                        {STATE_LABELS[m.state]}
                      </span>
                    </div>
                    <p style={styles.question}>{m.question}</p>
                    <div style={styles.reserves}>
                      <div style={styles.reserveBar}>
                        <div style={{...styles.yesBar, width: `${(Number(m.yes)/(Number(m.yes)+Number(m.no)))*100}%`}} />
                      </div>
                      <div style={styles.reserveLabels}>
                        <span style={{color:"#00ff80"}}>YES {Number(m.yes).toFixed(0)} USDC</span>
                        <span style={{color:"#ff4466"}}>NO {Number(m.no).toFixed(0)} USDC</span>
                      </div>
                    </div>
                    {m.outcome !== 0 && (
                      <div style={styles.outcomeTag}>
                        Outcome: <strong style={{color: m.outcome===1?"#00ff80":"#ff4466"}}>{OUTCOME_LABELS[m.outcome]}</strong>
                        {m.state === 2 && (
                          <button style={styles.btnSmall} onClick={() => handleRedeem(m.id)}>Redeem</button>
                        )}
                      </div>
                    )}
                  </div>
                ))}
              </div>
            )}

            {/* Subgraph section */}
            {subgraphMarkets.length > 0 && (
              <div style={{marginTop: 40}}>
                <h3 style={styles.subTitle}>📊 From The Graph (Indexed Data)</h3>
                <div style={styles.table}>
                  <div style={styles.tableHeader}>
                    <span>ID</span><span>Question</span><span>State</span><span>Collateral</span>
                  </div>
                  {subgraphMarkets.map(m => (
                    <div key={m.id} style={styles.tableRow}>
                      <span>#{m.id}</span>
                      <span style={{flex:2}}>{m.question}</span>
                      <span>{m.state}</span>
                      <span>{m.totalCollateral}</span>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        )}

        {/* TRADE TAB */}
        {tab === "trade" && (
          <div style={styles.twoCol}>
            {/* Buy Outcome */}
            <div style={styles.panel}>
              <h3 style={styles.panelTitle}>🔮 Buy Outcome</h3>
              <label style={styles.label}>Market ID</label>
              <input style={styles.input} value={buyMarketId} onChange={e=>setBuyMarketId(e.target.value)} placeholder="1" />
              <label style={styles.label}>Outcome</label>
              <div style={styles.toggle}>
                <button
                  style={buyIsYes ? styles.toggleActive : styles.toggleBtn}
                  onClick={() => setBuyIsYes(true)}
                >YES</button>
                <button
                  style={!buyIsYes ? {...styles.toggleActive, background:"rgba(255,68,102,0.3)", borderColor:"#ff4466", color:"#ff4466"} : styles.toggleBtn}
                  onClick={() => setBuyIsYes(false)}
                >NO</button>
              </div>
              <label style={styles.label}>Amount (USDC)</label>
              <input style={styles.input} value={buyAmount} onChange={e=>setBuyAmount(e.target.value)} placeholder="10" />
              <button style={styles.btnPrimary} onClick={handleBuy} disabled={loading}>
                {loading ? "Processing..." : `Buy ${buyIsYes?"YES":"NO"} Tokens`}
              </button>
            </div>

            {/* Create Market */}
            <div style={styles.panel}>
              <h3 style={styles.panelTitle}>🏗️ Create Market</h3>
              <label style={styles.label}>Question</label>
              <input style={styles.input} value={createQuestion} onChange={e=>setCreateQuestion(e.target.value)} placeholder="Will ETH > $5000?" />
              <label style={styles.label}>Resolution Time</label>
              <input style={styles.input} type="datetime-local" value={createResTime} onChange={e=>setCreateResTime(e.target.value)} />
              <div style={{display:"flex",gap:12}}>
                <div style={{flex:1}}>
                  <label style={styles.label}>Initial YES (USDC)</label>
                  <input style={styles.input} value={createInitYes} onChange={e=>setCreateInitYes(e.target.value)} />
                </div>
                <div style={{flex:1}}>
                  <label style={styles.label}>Initial NO (USDC)</label>
                  <input style={styles.input} value={createInitNo} onChange={e=>setCreateInitNo(e.target.value)} />
                </div>
              </div>
              <button style={styles.btnPrimary} onClick={handleCreateMarket} disabled={loading}>
                {loading ? "Processing..." : "Create Market"}
              </button>
            </div>
          </div>
        )}

        {/* GOVERNANCE TAB */}
        {tab === "governance" && (
          <div style={styles.twoCol}>
            {/* Voting Power */}
            <div style={styles.panel}>
              <h3 style={styles.panelTitle}>⚡ Voting Power</h3>
              <div style={styles.statRow}>
                <span style={styles.statLabel}>PRED Balance</span>
                <span style={styles.statValue}>{Number(govBalance).toFixed(2)}</span>
              </div>
              <div style={styles.statRow}>
                <span style={styles.statLabel}>Voting Power</span>
                <span style={{...styles.statValue, color:"#00ff80"}}>{Number(votingPower).toFixed(2)}</span>
              </div>
              <div style={styles.statRow}>
                <span style={styles.statLabel}>Delegate</span>
                <span style={styles.statValueSm}>{delegateAddr ? delegateAddr.slice(0,10)+"..." : "None"}</span>
              </div>
              <button style={styles.btnPrimary} onClick={handleDelegate} disabled={loading}>
                Delegate to Self
              </button>

              <div style={{borderTop:"1px solid #1a2a1a", marginTop:20, paddingTop:20}}>
                <h4 style={{color:"#88ff88", marginBottom:12}}>Create Proposal</h4>
                <label style={styles.label}>Description</label>
                <input style={styles.input} value={propDesc} onChange={e=>setPropDesc(e.target.value)} placeholder="Proposal description..." />
                <button style={styles.btnSecondary} onClick={handlePropose} disabled={loading}>
                  Submit Proposal
                </button>
              </div>
            </div>

            {/* Vote */}
            <div style={styles.panel}>
              <h3 style={styles.panelTitle}>🗳️ Cast Vote</h3>
              <label style={styles.label}>Proposal ID</label>
              <input style={styles.input} value={voteProposalId} onChange={e=>setVoteProposalId(e.target.value)} placeholder="0x..." />
              <label style={styles.label}>Vote</label>
              <div style={styles.toggle}>
                {[["0","Against"],["1","For"],["2","Abstain"]].map(([v,l]) => (
                  <button
                    key={v}
                    style={voteSupport===v ? styles.toggleActive : styles.toggleBtn}
                    onClick={() => setVoteSupport(v)}
                  >{l}</button>
                ))}
              </div>
              <button style={styles.btnPrimary} onClick={handleVote} disabled={loading}>
                Cast Vote
              </button>

              <div style={{marginTop:24, padding:16, background:"rgba(0,255,128,0.05)", borderRadius:8, border:"1px solid rgba(0,255,128,0.1)"}}>
                <div style={{color:"#88ff88", fontSize:12, marginBottom:8}}>Governor Parameters</div>
                <div style={styles.statRow}><span style={styles.statLabel}>Voting Delay</span><span style={styles.statValue}>~1 day</span></div>
                <div style={styles.statRow}><span style={styles.statLabel}>Voting Period</span><span style={styles.statValue}>~1 week</span></div>
                <div style={styles.statRow}><span style={styles.statLabel}>Quorum</span><span style={styles.statValue}>4%</span></div>
                <div style={styles.statRow}><span style={styles.statLabel}>Timelock</span><span style={styles.statValue}>2 days</span></div>
              </div>
            </div>
          </div>
        )}

        {/* PORTFOLIO TAB */}
        {tab === "portfolio" && (
          <div style={styles.panel}>
            <h3 style={styles.panelTitle}>💼 Your Portfolio</h3>
            {!account ? (
              <div style={styles.empty}>Connect wallet to view portfolio</div>
            ) : (
              <div>
                <div style={styles.statRow}>
                  <span style={styles.statLabel}>USDC Balance</span>
                  <span style={styles.statValue}>{Number(usdcBalance).toFixed(2)} USDC</span>
                </div>
                <div style={styles.statRow}>
                  <span style={styles.statLabel}>PRED Token</span>
                  <span style={styles.statValue}>{Number(govBalance).toFixed(2)} PRED</span>
                </div>
                <div style={styles.statRow}>
                  <span style={styles.statLabel}>Voting Power</span>
                  <span style={{...styles.statValue, color:"#00ff80"}}>{Number(votingPower).toFixed(2)}</span>
                </div>
                <div style={{marginTop:24}}>
                  <div style={{color:"#88ff88", fontSize:13, marginBottom:12}}>Deployed Contracts</div>
                  {Object.entries(ADDRESSES).map(([k,v]) => (
                    <div key={k} style={styles.addressRow}>
                      <span style={{color:"#557755", textTransform:"uppercase", fontSize:11, width:100}}>{k}</span>
                      <a
                        href={`https://sepolia.arbiscan.io/address/${v}`}
                        target="_blank"
                        rel="noreferrer"
                        style={{color:"#00cc66", fontSize:12, fontFamily:"monospace"}}
                      >{v}</a>
                    </div>
                  ))}
                </div>
                <button
                  style={{...styles.btnSecondary, marginTop:20}}
                  onClick={() => loadBalances(provider, signer, account)}
                >
                  Refresh Balances
                </button>
              </div>
            )}
          </div>
        )}
      </main>

      <footer style={styles.footer}>
        <span>Prediction Market Protocol</span>
        <span style={{color:"#334433"}}>•</span>
        <span>Arbitrum Sepolia</span>
        <span style={{color:"#334433"}}>•</span>
        <a href="https://sepolia.arbiscan.io/address/0x374EEa8313b50528C03cFa509c9505F8E0B1b5B7"
           target="_blank" rel="noreferrer" style={{color:"#00cc66"}}>
          View on Arbiscan ↗
        </a>
      </footer>
    </div>
  );
}

// ── Styles ────────────────────────────────────────────────────────────────────
const styles = {
  app: { minHeight:"100vh", background:"#050d05", color:"#ccddcc", fontFamily:"'Courier New', monospace", position:"relative", overflow:"hidden" },
  noise: { position:"fixed", inset:0, backgroundImage:"url(\"data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)' opacity='0.03'/%3E%3C/svg%3E\")", pointerEvents:"none", zIndex:0 },
  header: { display:"flex", justifyContent:"space-between", alignItems:"center", padding:"20px 32px", borderBottom:"1px solid #0a1a0a", position:"relative", zIndex:1 },
  logo: { display:"flex", alignItems:"center", gap:8 },
  logoIcon: { fontSize:24, color:"#00ff80" },
  logoText: { fontSize:20, fontWeight:700, letterSpacing:4, color:"#00ff80" },
  logoSub: { fontSize:10, letterSpacing:6, color:"#336633", marginTop:2 },
  headerRight: { display:"flex", alignItems:"center", gap:12 },
  balances: { display:"flex", gap:8 },
  badge: { padding:"4px 10px", background:"rgba(0,255,128,0.08)", border:"1px solid rgba(0,255,128,0.2)", borderRadius:4, fontSize:12, color:"#88bb88" },
  btnConnect: { padding:"10px 24px", background:"transparent", border:"1px solid #00ff80", color:"#00ff80", cursor:"pointer", letterSpacing:2, fontSize:12, fontFamily:"inherit", transition:"all 0.2s" },
  btnConnected: { padding:"10px 24px", background:"rgba(0,255,128,0.1)", border:"1px solid #336633", color:"#88bb88", cursor:"pointer", letterSpacing:1, fontSize:12, fontFamily:"inherit" },
  wrongNetwork: { background:"rgba(255,100,0,0.1)", border:"1px solid rgba(255,100,0,0.3)", color:"#ff8844", padding:"12px 32px", display:"flex", alignItems:"center", gap:16, fontSize:13 },
  switchBtn: { padding:"6px 16px", background:"transparent", border:"1px solid #ff8844", color:"#ff8844", cursor:"pointer", fontFamily:"inherit", fontSize:12 },
  statusBar: { margin:"0 32px", padding:"10px 16px", background:"rgba(0,20,0,0.8)", border:"1px solid", borderRadius:4, fontSize:13, color:"#aabbaa", position:"relative", zIndex:1 },
  nav: { display:"flex", gap:0, padding:"0 32px", borderBottom:"1px solid #0a1a0a", position:"relative", zIndex:1 },
  navBtn: { padding:"14px 24px", background:"transparent", border:"none", borderBottom:"2px solid transparent", color:"#445544", cursor:"pointer", letterSpacing:2, fontSize:11, fontFamily:"inherit", transition:"all 0.2s" },
  navBtnActive: { padding:"14px 24px", background:"transparent", border:"none", borderBottom:"2px solid #00ff80", color:"#00ff80", cursor:"pointer", letterSpacing:2, fontSize:11, fontFamily:"inherit" },
  main: { padding:"32px", position:"relative", zIndex:1, maxWidth:1200, margin:"0 auto" },
  sectionHeader: { marginBottom:24 },
  sectionTitle: { fontSize:20, color:"#00ff80", letterSpacing:2, margin:0 },
  sectionSub: { fontSize:11, color:"#334433", letterSpacing:3 },
  grid: { display:"grid", gridTemplateColumns:"repeat(auto-fill, minmax(320px, 1fr))", gap:16 },
  card: { background:"rgba(0,20,0,0.6)", border:"1px solid #0f2010", borderRadius:8, padding:20, transition:"border-color 0.2s" },
  cardHeader: { display:"flex", justifyContent:"space-between", alignItems:"center", marginBottom:12 },
  marketId: { color:"#334433", fontSize:11, letterSpacing:2 },
  statePill: { padding:"3px 10px", borderRadius:12, fontSize:11, letterSpacing:1 },
  question: { color:"#aabbaa", fontSize:14, lineHeight:1.5, marginBottom:16 },
  reserves: { marginBottom:12 },
  reserveBar: { height:4, background:"#0a1a0a", borderRadius:2, overflow:"hidden", marginBottom:8 },
  yesBar: { height:"100%", background:"linear-gradient(90deg,#00ff80,#00cc66)", borderRadius:2, transition:"width 0.5s" },
  reserveLabels: { display:"flex", justifyContent:"space-between", fontSize:11 },
  outcomeTag: { display:"flex", alignItems:"center", gap:8, fontSize:12, color:"#88aa88", marginTop:8 },
  btnSmall: { padding:"4px 12px", background:"rgba(0,255,128,0.1)", border:"1px solid #00ff80", color:"#00ff80", cursor:"pointer", fontFamily:"inherit", fontSize:11, borderRadius:4 },
  empty: { textAlign:"center", padding:"60px 0", color:"#334433", display:"flex", flexDirection:"column", alignItems:"center", gap:16 },
  subTitle: { color:"#88aa88", fontSize:14, letterSpacing:2, marginBottom:16 },
  table: { border:"1px solid #0f2010", borderRadius:8, overflow:"hidden" },
  tableHeader: { display:"grid", gridTemplateColumns:"60px 1fr 120px 120px", gap:16, padding:"10px 16px", background:"rgba(0,255,128,0.05)", fontSize:11, color:"#445544", letterSpacing:2 },
  tableRow: { display:"grid", gridTemplateColumns:"60px 1fr 120px 120px", gap:16, padding:"10px 16px", borderTop:"1px solid #0a1a0a", fontSize:12, color:"#88aa88" },
  twoCol: { display:"grid", gridTemplateColumns:"1fr 1fr", gap:24 },
  panel: { background:"rgba(0,20,0,0.6)", border:"1px solid #0f2010", borderRadius:8, padding:24 },
  panelTitle: { color:"#00ff80", fontSize:14, letterSpacing:2, marginBottom:20, marginTop:0 },
  label: { display:"block", fontSize:11, color:"#445544", letterSpacing:2, marginBottom:6, marginTop:14 },
  input: { width:"100%", padding:"10px 12px", background:"rgba(0,10,0,0.8)", border:"1px solid #0f2010", color:"#aabbaa", fontFamily:"inherit", fontSize:13, borderRadius:4, boxSizing:"border-box", outline:"none" },
  toggle: { display:"flex", gap:8, marginBottom:4 },
  toggleBtn: { flex:1, padding:"8px", background:"transparent", border:"1px solid #1a2a1a", color:"#445544", cursor:"pointer", fontFamily:"inherit", fontSize:12, borderRadius:4 },
  toggleActive: { flex:1, padding:"8px", background:"rgba(0,255,128,0.15)", border:"1px solid #00ff80", color:"#00ff80", cursor:"pointer", fontFamily:"inherit", fontSize:12, borderRadius:4 },
  btnPrimary: { width:"100%", padding:"12px", background:"rgba(0,255,128,0.15)", border:"1px solid #00ff80", color:"#00ff80", cursor:"pointer", fontFamily:"inherit", fontSize:13, letterSpacing:2, borderRadius:4, marginTop:16, transition:"all 0.2s" },
  btnSecondary: { width:"100%", padding:"12px", background:"transparent", border:"1px solid #336633", color:"#88aa88", cursor:"pointer", fontFamily:"inherit", fontSize:13, letterSpacing:2, borderRadius:4, marginTop:16 },
  statRow: { display:"flex", justifyContent:"space-between", alignItems:"center", padding:"8px 0", borderBottom:"1px solid #0a1a0a" },
  statLabel: { fontSize:12, color:"#445544", letterSpacing:1 },
  statValue: { fontSize:14, color:"#aabbaa", fontWeight:600 },
  statValueSm: { fontSize:11, color:"#aabbaa", fontFamily:"monospace" },
  addressRow: { display:"flex", alignItems:"center", gap:12, padding:"6px 0", borderBottom:"1px solid #050d05" },
  footer: { textAlign:"center", padding:"24px", borderTop:"1px solid #0a1a0a", fontSize:11, color:"#334433", letterSpacing:2, display:"flex", justifyContent:"center", gap:16, position:"relative", zIndex:1 },
};
