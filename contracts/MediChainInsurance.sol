// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title  MediChainInsurance
 * @notice Parametric micro-insurance for MediChain+ - pays USDC on verified prescriptions.
 * @dev    Diagnosis hashes are validated by Hyperledger Fabric, then relayed by the oracle
 *         (hospital multisig or Chainlink) to trigger automatic USDC payout.
 *
 * Security model:
 *  - oracle != insurer != admin (enforced in constructor)
 *  - emergencyWithdraw: nonReentrant + whenNotPaused + event + bounds check
 *  - claim expiry: 30 days default, configurable by admin
 *  - coverage snapshot: stored at claim time, immune to post-submission changes
 *  - receive/fallback: revert to prevent accidental ETH lockup
 */
contract MediChainInsurance is AccessControl, ReentrancyGuard, Pausable {

    bytes32 public constant ORACLE_ROLE  = keccak256("ORACLE_ROLE");
    bytes32 public constant INSURER_ROLE = keccak256("INSURER_ROLE");

    IERC20  public immutable stablecoin;
    uint256 public coveragePercent  = 85;           // 85% coverage
    uint256 public maxClaimAmount   = 5_000 * 1e6;  // 5000 USDC (6 decimals)
    uint256 public claimExpiryDays  = 30;            // claims expire after 30 days

    enum Status { None, Pending, Paid, Rejected }

    struct Claim {
        address patient;
        bytes32 diagnosisHash;
        uint256 amount;
        uint256 timestamp;
        uint256 deadline;            // expiry = timestamp + claimExpiryDays * 1 days
        uint256 coverageAtSubmission; // snapshot: immune to admin changes after submission
        Status  status;
    }

    mapping(bytes32 => Claim) public claims;
    uint256 public totalClaims;
    uint256 public totalPaid;

    /* ---------------------------------------------------------------- Events */

    event ClaimSubmitted   (bytes32 indexed id, address indexed patient, uint256 amount);
    event ClaimPaid        (bytes32 indexed id, address indexed patient, uint256 payout);
    event ClaimRejected    (bytes32 indexed id, string reason);
    event CoverageUpdated  (uint256 oldValue, uint256 newValue);
    event MaxClaimUpdated  (uint256 oldValue, uint256 newValue);
    event ExpiryUpdated    (uint256 oldDays, uint256 newDays);
    event EmergencyWithdraw(address indexed to, uint256 amount, address indexed by);

    /* -------------------------------------------------------------- Constructor */

    constructor(address _stablecoin, address _oracle, address _insurer) {
        require(_stablecoin != address(0), "stablecoin=0");
        require(_oracle     != address(0), "oracle=0");
        require(_insurer    != address(0), "insurer=0");
        // CRITICAL-01 fix: enforce role separation
        require(_oracle  != _insurer,    "oracle cannot be insurer");
        require(_oracle  != msg.sender,  "admin cannot be oracle");
        require(_insurer != msg.sender,  "admin cannot be insurer");

        stablecoin = IERC20(_stablecoin);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE,        _oracle);
        _grantRole(INSURER_ROLE,       _insurer);
    }

    /* -------------------------------------------------------------- Submission */

    function submitClaim(
        bytes32 id,
        address patient,
        bytes32 diagHash,
        uint256 amount
    ) external onlyRole(INSURER_ROLE) whenNotPaused {
        require(claims[id].status == Status.None, "Claim exists");
        require(patient != address(0),            "patient=0");
        require(amount > 0 && amount <= maxClaimAmount, "bad amount");

        claims[id] = Claim({
            patient:              patient,
            diagnosisHash:        diagHash,
            amount:               amount,
            timestamp:            block.timestamp,
            deadline:             block.timestamp + (claimExpiryDays * 1 days),
            coverageAtSubmission: coveragePercent,
            status:               Status.Pending
        });
        totalClaims++;
        emit ClaimSubmitted(id, patient, amount);
    }

    /* -------------------------------------------------------------- Validation */

    function validateAndPay(bytes32 id, bytes32 proofHash)
        external
        onlyRole(ORACLE_ROLE)
        nonReentrant
        whenNotPaused
    {
        Claim storage c = claims[id];
        require(c.status == Status.Pending,          "Not pending");
        require(block.timestamp <= c.deadline,       "Claim expired");
        require(c.diagnosisHash == proofHash,        "Hash mismatch");

        address patient = c.patient;  // cache before external call — Slither CEI
        uint256 payout    = (c.amount * c.coverageAtSubmission) / 100;
        require(stablecoin.balanceOf(address(this)) >= payout, "Insufficient treasury");

        c.status = Status.Paid;
        totalPaid += payout;

        require(stablecoin.transfer(patient, payout), "Transfer failed");
        emit ClaimPaid(id, patient, payout);
    }

    function rejectClaim(bytes32 id, string calldata reason)
        external onlyRole(ORACLE_ROLE) whenNotPaused
    {
        Claim storage c = claims[id];
        require(c.status == Status.Pending, "Not pending");
        c.status = Status.Rejected;
        emit ClaimRejected(id, reason);
    }

    /* ----------------------------------------------------------------- Admin */

    function setCoverage(uint256 pct) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pct > 0 && pct <= 100, "coverage must be 1-100");
        emit CoverageUpdated(coveragePercent, pct);
        coveragePercent = pct;
    }

    function setMaxClaimAmount(uint256 v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(v > 0, "max=0 would block all claims");
        emit MaxClaimUpdated(maxClaimAmount, v);
        maxClaimAmount = v;
    }

    function setClaimExpiryDays(uint256 d) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(d >= 1 && d <= 365, "expiry must be 1-365 days");
        emit ExpiryUpdated(claimExpiryDays, d);
        claimExpiryDays = d;
    }

    function pause()   external onlyRole(DEFAULT_ADMIN_ROLE) { _pause();   }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function emergencyWithdraw(address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        require(to != address(0), "to=0");
        require(amount > 0, "amount=0");
        require(amount <= stablecoin.balanceOf(address(this)), "exceeds treasury balance");
        emit EmergencyWithdraw(to, amount, msg.sender);
        require(stablecoin.transfer(to, amount), "Transfer failed");
    }

    /* ------------------------------------------------------------------ Views */

    function getClaim(bytes32 id) external view returns (Claim memory) {
        return claims[id];
    }

    function treasuryBalance() external view returns (uint256) {
        return stablecoin.balanceOf(address(this));
    }

    /* ---------------------------------------------------------------- Fallback */

    receive()  external payable { revert("No native token accepted"); }
    fallback() external payable { revert("No native token accepted"); }
}
