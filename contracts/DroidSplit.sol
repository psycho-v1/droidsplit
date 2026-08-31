// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PublisherRegistry} from "./PublisherRegistry.sol";
import {PullVault} from "./PullVault.sol";

/// @title DroidSplit
/// @notice Ownerless protocol: split router + usage pool + automatic bounties.
///         Registry address is immutable. No Ownable, pause, proxy, or setters.
contract DroidSplit is PullVault {
    PublisherRegistry public immutable registry;

    uint16 public constant BPS = 10_000;
    uint256 public constant SPLIT_FREEZE_DELAY = 7 days;
    uint8 public constant MAX_RECIPIENTS = 16;
    uint256 public constant EPOCH = 7 days;
    uint256 public constant USAGE_BOND = 0.001 ether;
    uint256 public constant MIN_BOUNTY = 0.01 ether;
    uint256 public constant CLAIM_BOND = 0.01 ether;
    uint256 public constant CHALLENGE_BOND = 0.02 ether;
    uint256 public constant CHALLENGE_WINDOW = 3 days;
    uint256 public constant VOTE_WINDOW = 3 days;
    uint8 public constant MAX_ATTESTORS = 32;

    struct Recipient {
        address to;
        uint16 bps;
    }

    struct SplitTable {
        Recipient[] recipients;
        uint256 pendingSince;
        bool frozen;
        bool exists;
    }

    mapping(bytes32 => SplitTable) private _live;
    mapping(bytes32 => SplitTable) private _pending;

    mapping(uint256 => mapping(bytes32 => uint256)) public epochScore;
    mapping(uint256 => uint256) public epochPool;
    mapping(uint256 => mapping(bytes32 => bool)) public epochPaid;
    mapping(uint256 => bytes32[]) private _epochLibs;
    mapping(uint256 => mapping(bytes32 => bool)) private _epochLibSeen;
    mapping(bytes32 => mapping(address => uint256)) public lastPulse;

    enum Pred {
        Preimage,
        AttestN,
        Optimistic
    }

    enum Status {
        Open,
        Challenging,
        Disputed,
        Paid,
        Refunded
    }

    struct Bounty {
        address creator;
        bytes32 subject;
        Pred pred;
        bytes32 target;
        uint32 attestN;
        uint256 reward;
        uint256 deadline;
        Status status;
        address claimant;
        bytes32 evidenceHash;
        string evidenceURI;
        uint256 claimAt;
        address challenger;
        string counterURI;
        uint256 challengeAt;
        uint256 yesBond;
        uint256 noBond;
        bool subjectIsApp;
    }

    uint256 public bountyCount;
    mapping(uint256 => Bounty) public bounties;
    mapping(uint256 => mapping(address => uint256)) public yesVote;
    mapping(uint256 => mapping(address => uint256)) public noVote;

    event SplitProposed(bytes32 indexed appId, uint256 freezeAt);
    event SplitFrozen(bytes32 indexed appId);
    event PaidIn(bytes32 indexed appId, address indexed from, uint256 amount);
    event Pulse(bytes32 indexed appId, address indexed from, uint256 epoch, bytes32[] libIds);
    event EpochFunded(uint256 indexed epoch, uint256 amount);
    event EpochDistributed(uint256 indexed epoch, bytes32 indexed libId, uint256 amount);
    event BountyCreated(uint256 indexed id, address indexed creator, Pred pred, uint256 reward);
    event BountyClaimed(uint256 indexed id, address indexed claimant);
    event BountyChallenged(uint256 indexed id, address indexed challenger);
    event Voted(uint256 indexed id, address indexed voter, bool yes, uint256 amount);
    event BountyFinalized(uint256 indexed id, Status status);

    error OnlyPublisher();
    error UnknownApp();
    error UnknownLib();
    error BadBps();
    error TooMany();
    error AlreadyFrozen();
    error NotReady();
    error Nothing();
    error Cooldown();
    error BadValue();
    error BadState();
    error TooLate();
    error TooEarly();
    error HashMismatch();
    error NotEnoughAttestations();
    error AlreadyVoted();
    error ZeroRegistry();
    error NotDep();
    error DepsUnlocked();
    error EmptyEvidence();
    error SelfChallenge();
    error DupAttestor();
    error ZeroTarget();

    constructor(address registry_) {
        if (registry_ == address(0)) revert ZeroRegistry();
        registry = PublisherRegistry(registry_);
    }

    receive() external payable {
        uint256 e = currentEpoch();
        epochPool[e] += msg.value;
        emit EpochFunded(e, msg.value);
    }

    // =====================================================================
    // Splits
    // =====================================================================

    /// @notice First proposal starts the freeze clock. Later edits keep that clock.
    ///         Publisher cannot reset the 7-day delay by re-proposing.
    function proposeSplit(bytes32 appId, address[] calldata tos, uint16[] calldata bps) external {
        if (!registry.appExists(appId)) revert UnknownApp();
        if (registry.publisherOfApp(appId) != msg.sender) revert OnlyPublisher();
        if (_live[appId].frozen) revert AlreadyFrozen();
        if (tos.length != bps.length || tos.length == 0 || tos.length > MAX_RECIPIENTS) revert TooMany();

        uint256 sum;
        delete _pending[appId].recipients;
        for (uint256 i; i < tos.length; ++i) {
            if (tos[i] == address(0) || bps[i] == 0) revert BadBps();
            sum += bps[i];
            _pending[appId].recipients.push(Recipient(tos[i], bps[i]));
        }
        if (sum != BPS) revert BadBps();

        if (_pending[appId].pendingSince == 0) {
            _pending[appId].pendingSince = block.timestamp;
        }
        _pending[appId].exists = true;
        emit SplitProposed(appId, _pending[appId].pendingSince + SPLIT_FREEZE_DELAY);
    }

    function freezeSplit(bytes32 appId) external {
        SplitTable storage p = _pending[appId];
        if (!p.exists) revert Nothing();
        if (_live[appId].frozen) revert AlreadyFrozen();
        if (block.timestamp < p.pendingSince + SPLIT_FREEZE_DELAY) revert NotReady();

        delete _live[appId].recipients;
        for (uint256 i; i < p.recipients.length; ++i) {
            _live[appId].recipients.push(p.recipients[i]);
        }
        _live[appId].frozen = true;
        _live[appId].exists = true;
        emit SplitFrozen(appId);
    }

    function pay(bytes32 appId) external payable {
        if (msg.value == 0) revert BadValue();
        if (!registry.appExists(appId)) revert UnknownApp();
        emit PaidIn(appId, msg.sender, msg.value);

        SplitTable storage live = _live[appId];
        if (!live.frozen || live.recipients.length == 0) {
            credit(registry.publisherOfApp(appId), msg.value);
            return;
        }

        uint256 allocated;
        uint256 last = live.recipients.length - 1;
        for (uint256 i; i < last; ++i) {
            uint256 share = (msg.value * live.recipients[i].bps) / BPS;
            allocated += share;
            credit(live.recipients[i].to, share);
        }
        // last recipient gets dust so nothing sticks in the contract
        credit(live.recipients[last].to, msg.value - allocated);
    }

    function liveSplit(bytes32 appId) external view returns (Recipient[] memory, bool frozen) {
        return (_live[appId].recipients, _live[appId].frozen);
    }

    // =====================================================================
    // Usage pool
    // =====================================================================

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH;
    }

    function fundEpoch() external payable {
        if (msg.value == 0) revert BadValue();
        uint256 e = currentEpoch();
        epochPool[e] += msg.value;
        emit EpochFunded(e, msg.value);
    }

    /// @notice Only locked app dependencies can be scored. Pulse bond stays in the pool.
    function pulse(bytes32 appId, bytes32[] calldata libIds) external payable {
        if (msg.value != USAGE_BOND) revert BadValue();
        if (!registry.appExists(appId)) revert UnknownApp();
        if (!registry.depsLocked(appId)) revert DepsUnlocked();
        if (libIds.length == 0 || libIds.length > 16) revert TooMany();
        if (block.timestamp < lastPulse[appId][msg.sender] + 1 days) revert Cooldown();
        lastPulse[appId][msg.sender] = block.timestamp;

        uint256 e = currentEpoch();
        epochPool[e] += msg.value;

        for (uint256 i; i < libIds.length; ++i) {
            bytes32 libId = libIds[i];
            if (!registry.isDep(appId, libId)) revert NotDep();
            epochScore[e][libId] += 1;
            if (!_epochLibSeen[e][libId]) {
                _epochLibSeen[e][libId] = true;
                _epochLibs[e].push(libId);
            }
        }
        emit Pulse(appId, msg.sender, e, libIds);
    }

    function distributeEpoch(uint256 epoch, bytes32 libId) external {
        if (epoch >= currentEpoch()) revert NotReady();
        if (epochPaid[epoch][libId]) revert AlreadyFrozen();
        uint256 pool = epochPool[epoch];
        if (pool == 0) revert Nothing();

        uint256 total;
        bytes32[] storage list = _epochLibs[epoch];
        for (uint256 i; i < list.length; ++i) {
            total += epochScore[epoch][list[i]];
        }
        if (total == 0) revert Nothing();

        uint256 score = epochScore[epoch][libId];
        if (score == 0) revert Nothing();

        epochPaid[epoch][libId] = true;
        uint256 share = (pool * score) / total;
        credit(registry.publisherOfLib(libId), share);
        emit EpochDistributed(epoch, libId, share);
    }

    function epochLibs(uint256 epoch) external view returns (bytes32[] memory) {
        return _epochLibs[epoch];
    }

    // =====================================================================
    // Bounties
    // =====================================================================

    function createBounty(
        bytes32 subject,
        bool subjectIsApp,
        Pred pred,
        bytes32 target,
        uint32 attestN,
        uint256 deadline
    ) external payable returns (uint256 id) {
        if (msg.value < MIN_BOUNTY) revert BadValue();
        if (deadline <= block.timestamp) revert TooLate();
        if (subjectIsApp) {
            if (!registry.appExists(subject)) revert UnknownApp();
        } else if (!registry.libExists(subject)) {
            revert UnknownLib();
        }
        if (pred == Pred.Preimage && target == bytes32(0)) revert ZeroTarget();
        if (pred == Pred.AttestN && (attestN == 0 || !subjectIsApp)) revert NotEnoughAttestations();

        id = bountyCount++;
        Bounty storage b = bounties[id];
        b.creator = msg.sender;
        b.subject = subject;
        b.subjectIsApp = subjectIsApp;
        b.pred = pred;
        b.target = target;
        b.attestN = attestN;
        b.reward = msg.value;
        b.deadline = deadline;
        b.status = Status.Open;
        emit BountyCreated(id, msg.sender, pred, msg.value);
    }

    function claim(
        uint256 id,
        bytes32 evidenceHash,
        string calldata evidenceURI,
        bytes calldata preimage,
        address[] calldata attestors
    ) external payable {
        Bounty storage b = bounties[id];
        if (b.status != Status.Open) revert BadState();
        if (block.timestamp > b.deadline) revert TooLate();

        if (b.pred == Pred.Preimage) {
            if (preimage.length == 0 || keccak256(preimage) != b.target) revert HashMismatch();
            _payClaimant(b, id, msg.sender);
            return;
        }

        if (b.pred == Pred.AttestN) {
            _checkUniqueAttestors(b.subject, attestors, b.attestN);
            _payClaimant(b, id, msg.sender);
            return;
        }

        if (bytes(evidenceURI).length == 0) revert EmptyEvidence();
        if (msg.value != CLAIM_BOND) revert BadValue();
        b.status = Status.Challenging;
        b.claimant = msg.sender;
        b.evidenceHash = evidenceHash;
        b.evidenceURI = evidenceURI;
        b.claimAt = block.timestamp;
        emit BountyClaimed(id, msg.sender);
    }

    function challenge(uint256 id, string calldata counterURI) external payable {
        Bounty storage b = bounties[id];
        if (b.status != Status.Challenging) revert BadState();
        if (block.timestamp > b.claimAt + CHALLENGE_WINDOW) revert TooLate();
        if (msg.sender == b.claimant) revert SelfChallenge();
        if (bytes(counterURI).length == 0) revert EmptyEvidence();
        if (msg.value != CHALLENGE_BOND) revert BadValue();
        b.status = Status.Disputed;
        b.challenger = msg.sender;
        b.counterURI = counterURI;
        b.challengeAt = block.timestamp;
        emit BountyChallenged(id, msg.sender);
    }

    function vote(uint256 id, bool yes) external payable {
        Bounty storage b = bounties[id];
        if (b.status != Status.Disputed) revert BadState();
        if (block.timestamp > b.challengeAt + VOTE_WINDOW) revert TooLate();
        if (msg.value == 0) revert BadValue();
        if (yesVote[id][msg.sender] != 0 || noVote[id][msg.sender] != 0) revert AlreadyVoted();
        if (yes) {
            yesVote[id][msg.sender] = msg.value;
            b.yesBond += msg.value;
        } else {
            noVote[id][msg.sender] = msg.value;
            b.noBond += msg.value;
        }
        emit Voted(id, msg.sender, yes, msg.value);
    }

    function finalize(uint256 id) external {
        Bounty storage b = bounties[id];

        if (b.status == Status.Open) {
            if (block.timestamp <= b.deadline) revert TooEarly();
            b.status = Status.Refunded;
            credit(b.creator, b.reward);
            emit BountyFinalized(id, Status.Refunded);
            return;
        }

        if (b.status == Status.Challenging) {
            if (block.timestamp <= b.claimAt + CHALLENGE_WINDOW) revert TooEarly();
            _payClaimant(b, id, b.claimant);
            credit(b.claimant, CLAIM_BOND);
            return;
        }

        if (b.status != Status.Disputed) revert BadState();
        if (block.timestamp <= b.challengeAt + VOTE_WINDOW) revert TooEarly();

        // No votes: nobody put capital on the evidence. Refund both bonds, reopen.
        if (b.yesBond + b.noBond == 0) {
            address claimant = b.claimant;
            address challenger = b.challenger;
            b.status = Status.Open;
            b.claimant = address(0);
            b.challenger = address(0);
            b.claimAt = 0;
            b.challengeAt = 0;
            credit(claimant, CLAIM_BOND);
            credit(challenger, CHALLENGE_BOND);
            emit BountyFinalized(id, Status.Open);
            return;
        }

        bool claimWins = b.yesBond > b.noBond; // strict; tie reopens
        if (b.yesBond == b.noBond) {
            address claimant = b.claimant;
            address challenger = b.challenger;
            uint256 yes = b.yesBond;
            uint256 no = b.noBond;
            b.status = Status.Open;
            b.claimant = address(0);
            b.challenger = address(0);
            b.yesBond = 0;
            b.noBond = 0;
            credit(claimant, CLAIM_BOND);
            credit(challenger, CHALLENGE_BOND);
            // tie votes go back to the epoch pool — cannot enumerate voters
            epochPool[currentEpoch()] += yes + no;
            emit EpochFunded(currentEpoch(), yes + no);
            emit BountyFinalized(id, Status.Open);
            return;
        }

        uint256 loserPool = claimWins ? b.noBond : b.yesBond;
        uint256 winnerPool = claimWins ? b.yesBond : b.noBond;
        uint256 toPool = loserPool / 10;
        epochPool[currentEpoch()] += toPool;
        emit EpochFunded(currentEpoch(), toPool);

        if (claimWins) {
            address claimant = b.claimant;
            _payClaimant(b, id, claimant);
            credit(claimant, CLAIM_BOND);
            credit(claimant, CHALLENGE_BOND + loserPool - toPool + winnerPool);
        } else {
            address challenger = b.challenger;
            b.status = Status.Open;
            b.claimant = address(0);
            b.challenger = address(0);
            b.yesBond = 0;
            b.noBond = 0;
            credit(challenger, CHALLENGE_BOND);
            credit(challenger, CLAIM_BOND + loserPool - toPool + winnerPool);
            emit BountyFinalized(id, Status.Open);
        }
    }

    function _checkUniqueAttestors(bytes32 appId, address[] calldata attestors, uint32 need) internal view {
        if (attestors.length < need || attestors.length > MAX_ATTESTORS) revert NotEnoughAttestations();
        uint256 n;
        for (uint256 i; i < attestors.length; ++i) {
            address a = attestors[i];
            if (a == address(0) || !registry.isAttestedInstaller(appId, a)) continue;
            bool dup;
            for (uint256 j; j < i; ++j) {
                if (attestors[j] == a) {
                    dup = true;
                    break;
                }
            }
            if (dup) revert DupAttestor();
            n++;
        }
        if (n < need) revert NotEnoughAttestations();
    }

    function _payClaimant(Bounty storage b, uint256 id, address to) internal {
        b.status = Status.Paid;
        b.claimant = to;
        credit(to, b.reward);
        emit BountyClaimed(id, to);
        emit BountyFinalized(id, Status.Paid);
    }
}
