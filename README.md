<div align="center">

# MediChain+

**Parametric micro-insurance for pharmaceutical prescriptions**

Automated USDC disbursement the moment a prescription is dispensed —
no manual adjudication, no delays.

[![CI](https://github.com/omarbabba779xx/Medichain-plus/actions/workflows/ci.yml/badge.svg)](https://github.com/omarbabba779xx/Medichain-plus/actions/workflows/ci.yml)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue?logo=solidity)](contracts/MediChainInsurance.sol)
[![Fabric](https://img.shields.io/badge/Hyperledger_Fabric-2.5-green)](fabric-network/)
[![Polygon](https://img.shields.io/badge/Polygon-Amoy_testnet-8247e5?logo=polygon)](https://amoy.polygonscan.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

</div>

---

## How It Works

A prescription travels from hospital to pharmacy on a private Fabric ledger.
The moment it is dispensed, a Node.js bridge relayer translates the Fabric event
into a Solidity transaction — the patient's USDC lands in seconds.

```mermaid
sequenceDiagram
    participant H as Hospital (HospitalMSP)
    participant F as Fabric Ledger
    participant R as Bridge Relayer
    participant S as MediChainInsurance.sol
    participant P as Patient Wallet

    H->>F: IssuePrescription(rxId, patientId, diagHash)
    F-->>R: event PrescriptionIssued
    R->>S: submitClaim(id, patient, diagHash, amount)
    Note over S: status = Pending ⏳

    H->>F: FillPrescription(rxId)
    F-->>R: event PrescriptionDispensed
    R->>S: validateAndPay(id, proofHash)
    S->>P: USDC transfer (coverageAtSubmission %)
    Note over S: status = Paid ✅
```

---

## Architecture

```mermaid
graph TB
    subgraph Fabric["Hyperledger Fabric 2.5 — medichain-channel"]
        H[HospitalMSP<br/>peer0 · CA · CouchDB]
        Ph[PharmacyMSP<br/>peer0 · CA · CouchDB]
        O[Orderer — Raft]
        CC[Chaincode: medichain<br/>CCaaS mode]
        H --- CC
        Ph --- CC
        CC --- O
    end

    subgraph Relayer["Bridge Relayer (Node.js / ethers v6)"]
        RF[requireField — no zero-address fallback]
        WR[withRetry — 5× exponential back-off]
        CUR[cursor — last Fabric block persisted]
    end

    subgraph Polygon["Polygon Amoy — Solidity 0.8.20"]
        INS[MediChainInsurance.sol]
        USDC[USDC ERC-20 Treasury]
        INS --> USDC
    end

    Fabric -->|PrescriptionIssued<br/>PrescriptionDispensed| Relayer
    Relayer -->|submitClaim<br/>validateAndPay| Polygon
```

---

## Security Model

### Role Separation

```mermaid
graph LR
    A[Admin<br/>DEFAULT_ADMIN_ROLE]
    OR[Oracle<br/>ORACLE_ROLE]
    IN[Insurer<br/>INSURER_ROLE]

    A -->|pause / setCoverage / emergencyWithdraw| SC[Contract]
    OR -->|validateAndPay / rejectClaim| SC
    IN -->|submitClaim| SC

    A -. "≠" .- OR
    A -. "≠" .- IN
    OR -. "≠" .- IN

    style A fill:#e8f4f8,stroke:#2196F3
    style OR fill:#fff3e0,stroke:#FF9800
    style IN fill:#e8f5e9,stroke:#4CAF50
```

> Enforced in the constructor — deploying with overlapping roles reverts immediately.

### Claim State Machine

```mermaid
stateDiagram-v2
    [*] --> Pending : submitClaim() — INSURER_ROLE
    Pending --> Paid : validateAndPay() — ORACLE_ROLE\n(hash match + deadline not exceeded)
    Pending --> Rejected : rejectClaim() — ORACLE_ROLE
    Pending --> Pending : validateAndPay() after deadline → REVERT\n(status unchanged, claim stays Pending)
    Paid --> [*]
    Rejected --> [*]
```

### Chaincode Access Control

```mermaid
graph LR
    subgraph HospitalMSP
        IP["IssuePrescription\n(rxId, patientId, patientEthAddress,\ndoctorId, medication, dosage, price)"]
    end
    subgraph PharmacyMSP
        FP["FillPrescription\n(rxId) — pharmacistMSP from cert"]
    end
    subgraph AnyMSP
        GP[GetPrescription - read only]
    end
```

---

## Security Audit

All **19 findings** from the internal audit have been remediated.

| ID | Finding | Severity | Status |
|---|---|---|---|
| C-01 | Oracle/insurer role confusion in constructor | Critical | ✅ Fixed |
| C-02 | `emergencyWithdraw` missing reentrancy guard + bounds check | Critical | ✅ Fixed |
| C-03 | MSP access control absent in chaincode | Critical | ✅ Fixed |
| C-04 | `time.Now()` non-determinism across Fabric peers | Critical | ✅ Fixed |
| C-05 | `float64` monetary amounts (consensus non-determinism) | Critical | ✅ Fixed |
| C-06 | Bridge relayer silent fallback to zero-address | Critical | ✅ Fixed |
| H-01 | Claim expiry not enforced in `validateAndPay` | High | ✅ Fixed |
| H-02 | Coverage % changeable after claim submission | High | ✅ Fixed |
| H-03 | No retry logic in bridge relayer | High | ✅ Fixed |
| H-04 | No persistent event cursor in bridge relayer | High | ✅ Fixed |
| H-05 | `setMaxClaimAmount` missing validation | High | ✅ Fixed |
| H-06 | Missing `emergencyWithdraw` tests | High | ✅ Fixed |
| H-07 | Slither `continue-on-error` silencing high findings | High | ✅ Fixed |
| M-01 | MSP constant mismatch (`Org1MSP` vs `HospitalMSP`) | Medium | ✅ Fixed |
| M-02 | Missing `rejectClaim` tests | Medium | ✅ Fixed |
| M-03 | Gitleaks secrets scanning absent from CI | Medium | ✅ Fixed |
| M-04 | DPIA missing | Medium | ✅ Fixed |
| L-01 | `deployment.json` not in `.gitignore` | Low | ✅ Fixed |
| L-02 | CouchDB credentials hardcoded in docker-compose | Low | ✅ Fixed |
| L-03 | Native token lockup (missing receive/fallback revert) | Low | ✅ Fixed |

---

## CI/CD Pipeline

```mermaid
graph LR
    push([git push])
    push --> S[Gitleaks<br/>secrets scan]
    S --> SOL[Hardhat<br/>compile + test]
    S --> GO[Go chaincode<br/>build + test]
    S --> BR[Bridge<br/>smoke test]
    SOL --> SL[Slither<br/>fail-on: high]
    SL --> STATUS{Status gate}
    GO --> STATUS
    BR --> STATUS
    SOL --> SH[Solhint<br/>informational]
    SOL --> MY[Mythril<br/>informational]
    SOL --> SG[Semgrep<br/>informational]
    SH --> STATUS
    MY --> STATUS
    SG --> STATUS

    style S fill:#ffecb3
    style SOL fill:#e3f2fd
    style GO fill:#e8f5e9
    style BR fill:#fce4ec
    style SL fill:#fff3e0
    style STATUS fill:#ede7f6
```

| Job | Tool | Blocks merge |
|---|---|---|
| Secrets | Gitleaks CLI 8.x | Yes |
| Compile + test | Hardhat | Yes |
| Static analysis | Slither `fail-on: high` | Yes |
| Go build + test | `go test -race` | Yes |
| Bridge smoke | `relayer.js --mode=mock` | Yes |
| Style lint | Solhint | No |
| Symbolic exec | Mythril | No |
| SAST | Semgrep | No |

---

## Technology Stack

```mermaid
graph TB
    subgraph Smart_Contract["Smart Contract Layer"]
        SOL["Solidity 0.8.20"]
        OZ["OpenZeppelin v4\nAccessControl · ReentrancyGuard · Pausable"]
        USDC["USDC ERC-20"]
        SOL --> OZ
        SOL --> USDC
    end

    subgraph Fabric_Layer["Permissioned Ledger"]
        GO["Go 1.21"]
        API["fabric-contract-api-go"]
        COUCH["CouchDB — rich queries"]
        GO --> API
        GO --> COUCH
    end

    subgraph Bridge_Layer["Event Bridge"]
        NODE["Node.js ESM"]
        ETH["ethers v6"]
        NODE --> ETH
    end

    subgraph Infra["Infrastructure"]
        DOCKER["Docker Compose"]
        RAFT["Raft Orderer"]
        DOCKER --> RAFT
    end
```

---

## Repository Structure

```
Medichain-plus/
├── contracts/
│   ├── MediChainInsurance.sol     Solidity — USDC treasury + payout logic
│   └── MockERC20.sol              Test-only mock stablecoin
├── chaincode/
│   ├── medichain/
│   │   ├── medichain.go           Fabric chaincode — prescription lifecycle
│   │   ├── Dockerfile             Multi-stage Go build (CCaaS)
│   │   └── go.mod
│   ├── medical_records.go         Fabric chaincode — records + consent
│   ├── medical_records_test.go
│   └── go.mod
├── bridge/
│   ├── relayer.js                 Node.js bridge — Fabric → Polygon
│   ├── package.json
│   └── fixtures/
│       └── events.jsonl           Mock events for CI / local demo
├── fabric-network/
│   ├── docker-compose.yaml        2-org network (HospitalMSP + PharmacyMSP)
│   ├── configtx.yaml
│   ├── crypto-config/             MSP certificates
│   ├── channel-artifacts/
│   └── scripts/
│       └── deploy-ccaas.sh        One-shot deployment script
├── test/
│   └── MediChainInsurance.test.js Hardhat tests — unit + security
├── docs/
│   ├── DPIA.md                    GDPR Art. 35 impact assessment
│   └── HDS/                       French HDS compliance docs
├── .github/workflows/ci.yml       Full CI pipeline
├── hardhat.config.js
├── slither.config.json
└── .semgrep.yml
```

---

## Prerequisites

| Tool | Version |
|---|---|
| Docker + Docker Compose | 24+ |
| Go | 1.21+ |
| Node.js | 20+ |
| Hyperledger Fabric binaries | 2.5.6 (auto-downloaded) |

---

## Getting Started

### 1. Clone

```bash
git clone https://github.com/omarbabba779xx/Medichain-plus.git
cd Medichain-plus
```

### 2. Install dependencies

```bash
npm install
cd bridge && npm install && cd ..
```

### 3. Run Solidity tests

```bash
npx hardhat test
npx hardhat coverage    # generates coverage/index.html
```

### 4. Deploy the Fabric network (WSL2 / Linux)

```bash
bash fabric-network/scripts/deploy-ccaas.sh
```

This script:

```mermaid
graph LR
    A[Start dockerd] --> B[docker compose up]
    B --> C[Create medichain-channel]
    C --> D[Join both peers]
    D --> E[Build chaincode image]
    E --> F[Install CCaaS package]
    F --> G[Approve + commit both orgs]
    G --> H[Smoke test]
```

### 5. Deploy the Solidity contract (Polygon Amoy)

```bash
cp .env.example .env
# set PRIVATE_KEY and AMOY_RPC in .env
npx hardhat run scripts/deploy.js --network amoy
```

Contract address saved to `deployment.json` (git-ignored).

### 6. Run the bridge relayer

```bash
# Mock mode (no Fabric / Polygon needed — CI default):
node bridge/relayer.js --mode=mock --once

# Production:
export FABRIC_CONN_PROFILE=/path/to/connection-profile.json
export WALLET_PATH=/path/to/wallet
export PRIVATE_KEY=0x...
export CONTRACT_ADDRESS=0x...
node bridge/relayer.js --mode=real
```

The relayer writes `.relayer-cursor.json` after each event — on restart it resumes
from the last processed Fabric block with no missed or duplicate events.

---

## Environment Variables

### Bridge Relayer

| Variable | Required | Default | Description |
|---|---|---|---|
| `RELAYER_MODE` | No | `mock` | `real` or `mock` |
| `AMOY_RPC` | real only | Polygon public RPC | Polygon Amoy JSON-RPC endpoint |
| `PRIVATE_KEY` | real only | — | Oracle wallet private key (0x-hex) |
| `CONTRACT_ADDRESS` | real only | — | `MediChainInsurance` deployed address |
| `FABRIC_CONN_PROFILE` | real only | — | Fabric connection-profile JSON path |
| `WALLET_PATH` | real only | — | Fabric file-system wallet path |
| `USER_ID` | No | `admin` | Fabric identity name in wallet |
| `FABRIC_CHANNEL` | No | `medichain-channel` | Fabric channel name |
| `CHAINCODE_NAME` | No | `medichain` | Chaincode name |
| `CURSOR_FILE` | No | `bridge/.relayer-cursor.json` | Block cursor path |
| `BRIDGE_DEFAULT_PATIENT_ADDRESS` | No | — | Fallback ETH address if Fabric event omits `patientAddress` |

### Fabric Network

| Variable | Default | Description |
|---|---|---|
| `COUCHDB_PASSWORD` | `adminpw` | CouchDB password — **override in production** |

---

## Compliance

### GDPR / HDS

```mermaid
graph TB
    subgraph OnChain["On-chain (Fabric + Polygon)"]
        OID["Opaque patient UUID"]
        DH["keccak256(diagnosisHash)"]
        AM["Claim amount — USDC"]
    end
    subgraph OffChain["Off-chain (HDS infrastructure)"]
        PHI["Raw PHI\n(name, DOB, address)"]
        RX["Full prescription details"]
        IMG["Medical images / reports"]
    end

    PHI -. "never written on-chain" .-> OnChain
    style PHI fill:#ffcdd2
    style RX fill:#ffcdd2
    style IMG fill:#ffcdd2
    style OID fill:#c8e6c9
    style DH fill:#c8e6c9
    style AM fill:#c8e6c9
```

| Requirement | Status |
|---|---|
| DPIA (GDPR Art. 35) | Done — `docs/DPIA.md` |
| PHI never written on-chain | Enforced by design |
| HDS-certified infrastructure | Required before production |
| DPO appointment | Required before production |
| Patient privacy policy | Required before production |
| Data breach response procedure | Required before production |

> **Production note:** Polygon mainnet deployment requires a Data Processing Agreement
> with Polygon Labs and legal review of cross-border data flows.

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Ensure all tests pass: `npx hardhat test`
4. Ensure Slither passes: `npx slither contracts/`
5. Open a pull request — CI must be fully green before review

**Code standards:**
- Solidity: no `pragma experimental`; follow `.solhint.json`
- Go chaincode: `uint64` for all monetary values; no `time.Now()`; pass `go vet`
- Bridge: ESM modules; validate all external inputs via `requireField()`
- Tests: new contract functions require Hardhat test coverage

---

## License

MIT — see [LICENSE](LICENSE)

---

<div align="center">

Built on [Hyperledger Fabric](https://www.hyperledger.org/use/fabric) &nbsp;·&nbsp;
[Polygon](https://polygon.technology/) &nbsp;·&nbsp;
[OpenZeppelin](https://openzeppelin.com/)

</div>
