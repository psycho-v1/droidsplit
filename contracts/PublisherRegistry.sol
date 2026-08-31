// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title PublisherRegistry
/// @notice Ownerless app / library registry.
///         Names are claimed via commit–reveal + stake.
///         Expired unrevealed commits can be reclaimed by the committer.
///         Successful reveals lock the stake on the name (anti-squat).
///         Control moves only by two-step handover.
contract PublisherRegistry {
    uint256 public constant COMMIT_DELAY = 1 hours;
    uint256 public constant COMMIT_WINDOW = 24 hours;
    uint256 public constant NAME_STAKE = 0.01 ether;
    uint256 public constant ATTEST_FEE = 0.001 ether;
    uint256 public constant ATTEST_COOLDOWN = 1 days;
    uint8 public constant MAX_DEPS = 16;

    struct Publisher {
        bool registered;
        string metadataURI;
    }

    struct App {
        address publisher;
        string packageName;
        bytes32 certFingerprint;
        bytes32 apkHash;
        string playUrl;
        bool exists;
        bool depsLocked;
    }

    struct Lib {
        address publisher;
        string groupId;
        string artifactId;
        bool exists;
    }

    struct Commit {
        address committer;
        bytes32 hash;
        uint256 timestamp;
        uint256 stake;
        bool revealed;
        bool reclaimed;
    }

    struct Handover {
        address to;
        uint256 initiatedAt;
    }

    mapping(address => Publisher) public publishers;
    mapping(bytes32 => App) public apps;
    mapping(bytes32 => Lib) public libs;
    mapping(bytes32 => Commit) public commits;
    mapping(bytes32 => Handover) public appHandover;
    mapping(bytes32 => Handover) public libHandover;

    mapping(bytes32 => mapping(address => uint256)) public lastAttest;
    mapping(bytes32 => mapping(address => bool)) public attestedInstaller;

    mapping(bytes32 => mapping(bytes32 => bool)) public isDep; // appId => libId
    mapping(bytes32 => bytes32[]) private _deps;

    event PublisherRegistered(address indexed wallet, string metadataURI);
    event Committed(bytes32 indexed commitId, address indexed committer);
    event CommitReclaimed(bytes32 indexed commitId, address indexed committer, uint256 stake);
    event AppRegistered(bytes32 indexed appId, address indexed publisher, string packageName);
    event LibRegistered(bytes32 indexed libId, address indexed publisher, string groupId, string artifactId);
    event AppUpdated(bytes32 indexed appId, bytes32 certFingerprint, bytes32 apkHash);
    event DepsLocked(bytes32 indexed appId, bytes32[] libIds);
    event AppHandoverStarted(bytes32 indexed appId, address indexed from, address indexed to);
    event AppHandoverAccepted(bytes32 indexed appId, address indexed to);
    event LibHandoverStarted(bytes32 indexed libId, address indexed from, address indexed to);
    event LibHandoverAccepted(bytes32 indexed libId, address indexed to);
    event InstallAttested(bytes32 indexed appId, address indexed wallet);

    error AlreadyRegistered();
    error NotPublisher();
    error InvalidCommit();
    error CommitTooSoon();
    error CommitExpired();
    error CommitNotExpired();
    error AlreadyRevealed();
    error AlreadyReclaimed();
    error NameTaken();
    error Unknown();
    error BadStake();
    error ZeroAddress();
    error NoHandover();
    error NotRecipient();
    error Cooldown();
    error SelfHandover();
    error DepsAlreadyLocked();
    error TooMany();
    error TransferFailed();

    function registerPublisher(string calldata metadataURI) external {
        if (publishers[msg.sender].registered) revert AlreadyRegistered();
        publishers[msg.sender] = Publisher(true, metadataURI);
        emit PublisherRegistered(msg.sender, metadataURI);
    }

    function updatePublisherURI(string calldata metadataURI) external {
        if (!publishers[msg.sender].registered) revert NotPublisher();
        publishers[msg.sender].metadataURI = metadataURI;
    }

    /// @dev commitHash = keccak256(abi.encodePacked(kind, nameKey, salt, msg.sender))
    ///      kind = 1 app, nameKey = keccak256(bytes(packageName))
    ///      kind = 2 lib, nameKey = keccak256(abi.encodePacked(groupId, artifactId))
    function commit(bytes32 commitHash) external payable {
        if (msg.value != NAME_STAKE) revert BadStake();
        bytes32 commitId = keccak256(abi.encodePacked(msg.sender, commitHash, block.number));
        commits[commitId] = Commit(msg.sender, commitHash, block.timestamp, msg.value, false, false);
        emit Committed(commitId, msg.sender);
    }

    /// @notice If you never reveal, take the stake back after the window.
    function reclaimCommit(bytes32 commitId) external {
        Commit storage c = commits[commitId];
        if (c.committer != msg.sender) revert InvalidCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (c.reclaimed) revert AlreadyReclaimed();
        if (block.timestamp <= c.timestamp + COMMIT_WINDOW) revert CommitNotExpired();
        c.reclaimed = true;
        uint256 stake = c.stake;
        c.stake = 0;
        (bool ok, ) = payable(msg.sender).call{value: stake}("");
        if (!ok) revert TransferFailed();
        emit CommitReclaimed(commitId, msg.sender, stake);
    }

    function revealApp(
        bytes32 commitId,
        string calldata packageName,
        bytes32 certFingerprint,
        bytes32 apkHash,
        string calldata playUrl,
        bytes32 salt
    ) external {
        bytes32 nameKey = keccak256(bytes(packageName));
        bytes32 expected = keccak256(abi.encodePacked(uint8(1), nameKey, salt, msg.sender));
        _consumeCommit(commitId, expected);
        if (apps[nameKey].exists) revert NameTaken();

        apps[nameKey] = App({
            publisher: msg.sender,
            packageName: packageName,
            certFingerprint: certFingerprint,
            apkHash: apkHash,
            playUrl: playUrl,
            exists: true,
            depsLocked: false
        });
        emit AppRegistered(nameKey, msg.sender, packageName);
    }

    function revealLib(
        bytes32 commitId,
        string calldata groupId,
        string calldata artifactId,
        bytes32 salt
    ) external {
        bytes32 nameKey = keccak256(abi.encodePacked(groupId, artifactId));
        bytes32 expected = keccak256(abi.encodePacked(uint8(2), nameKey, salt, msg.sender));
        _consumeCommit(commitId, expected);
        if (libs[nameKey].exists) revert NameTaken();

        libs[nameKey] = Lib({
            publisher: msg.sender,
            groupId: groupId,
            artifactId: artifactId,
            exists: true
        });
        emit LibRegistered(nameKey, msg.sender, groupId, artifactId);
    }

    function updateAppRelease(
        bytes32 appId,
        bytes32 certFingerprint,
        bytes32 apkHash,
        string calldata playUrl
    ) external {
        App storage a = apps[appId];
        if (!a.exists) revert Unknown();
        if (a.publisher != msg.sender) revert NotPublisher();
        a.certFingerprint = certFingerprint;
        a.apkHash = apkHash;
        a.playUrl = playUrl;
        emit AppUpdated(appId, certFingerprint, apkHash);
    }

    /// @notice First call locks the dependency list forever. Required before pulses count.
    function lockDeps(bytes32 appId, bytes32[] calldata libIds) external {
        App storage a = apps[appId];
        if (!a.exists) revert Unknown();
        if (a.publisher != msg.sender) revert NotPublisher();
        if (a.depsLocked) revert DepsAlreadyLocked();
        if (libIds.length == 0 || libIds.length > MAX_DEPS) revert TooMany();

        for (uint256 i; i < libIds.length; ++i) {
            if (!libs[libIds[i]].exists) revert Unknown();
            if (isDep[appId][libIds[i]]) revert AlreadyRegistered();
            isDep[appId][libIds[i]] = true;
            _deps[appId].push(libIds[i]);
        }
        a.depsLocked = true;
        emit DepsLocked(appId, libIds);
    }

    function startAppHandover(bytes32 appId, address to) external {
        if (to == address(0)) revert ZeroAddress();
        App storage a = apps[appId];
        if (!a.exists) revert Unknown();
        if (a.publisher != msg.sender) revert NotPublisher();
        if (to == msg.sender) revert SelfHandover();
        appHandover[appId] = Handover(to, block.timestamp);
        emit AppHandoverStarted(appId, msg.sender, to);
    }

    function acceptAppHandover(bytes32 appId) external {
        Handover memory h = appHandover[appId];
        if (h.to == address(0)) revert NoHandover();
        if (h.to != msg.sender) revert NotRecipient();
        apps[appId].publisher = msg.sender;
        delete appHandover[appId];
        emit AppHandoverAccepted(appId, msg.sender);
    }

    function startLibHandover(bytes32 libId, address to) external {
        if (to == address(0)) revert ZeroAddress();
        Lib storage l = libs[libId];
        if (!l.exists) revert Unknown();
        if (l.publisher != msg.sender) revert NotPublisher();
        if (to == msg.sender) revert SelfHandover();
        libHandover[libId] = Handover(to, block.timestamp);
        emit LibHandoverStarted(libId, msg.sender, to);
    }

    function acceptLibHandover(bytes32 libId) external {
        Handover memory h = libHandover[libId];
        if (h.to == address(0)) revert NoHandover();
        if (h.to != msg.sender) revert NotRecipient();
        libs[libId].publisher = msg.sender;
        delete libHandover[libId];
        emit LibHandoverAccepted(libId, msg.sender);
    }

    /// @notice Paid, rate-limited self-attestation. Still sybil-able at a cost.
    function attestInstall(bytes32 appId) external payable {
        if (msg.value != ATTEST_FEE) revert BadStake();
        if (!apps[appId].exists) revert Unknown();
        if (block.timestamp < lastAttest[appId][msg.sender] + ATTEST_COOLDOWN) revert Cooldown();
        lastAttest[appId][msg.sender] = block.timestamp;
        attestedInstaller[appId][msg.sender] = true;
        emit InstallAttested(appId, msg.sender);
    }

    function publisherOfApp(bytes32 appId) external view returns (address) {
        return apps[appId].publisher;
    }

    function publisherOfLib(bytes32 libId) external view returns (address) {
        return libs[libId].publisher;
    }

    function appExists(bytes32 appId) external view returns (bool) {
        return apps[appId].exists;
    }

    function libExists(bytes32 libId) external view returns (bool) {
        return libs[libId].exists;
    }

    function depsLocked(bytes32 appId) external view returns (bool) {
        return apps[appId].depsLocked;
    }

    function isAttestedInstaller(bytes32 appId, address wallet) external view returns (bool) {
        return attestedInstaller[appId][wallet];
    }

    function depsOf(bytes32 appId) external view returns (bytes32[] memory) {
        return _deps[appId];
    }

    function appIdOf(string calldata packageName) external pure returns (bytes32) {
        return keccak256(bytes(packageName));
    }

    function libIdOf(string calldata groupId, string calldata artifactId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(groupId, artifactId));
    }

    function _consumeCommit(bytes32 commitId, bytes32 expected) internal {
        Commit storage c = commits[commitId];
        if (c.committer != msg.sender || c.hash != expected) revert InvalidCommit();
        if (c.revealed) revert AlreadyRevealed();
        if (c.reclaimed) revert AlreadyReclaimed();
        if (block.timestamp < c.timestamp + COMMIT_DELAY) revert CommitTooSoon();
        if (block.timestamp > c.timestamp + COMMIT_WINDOW) revert CommitExpired();
        c.revealed = true;
    }
}
