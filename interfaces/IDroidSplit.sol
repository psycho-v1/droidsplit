// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IPublisherRegistry {
    function publisherOfApp(bytes32 appId) external view returns (address);
    function publisherOfLib(bytes32 libId) external view returns (address);
    function appExists(bytes32 appId) external view returns (bool);
    function libExists(bytes32 libId) external view returns (bool);
    function isAttestedInstaller(bytes32 appId, address wallet) external view returns (bool);
    function isDep(bytes32 appId, bytes32 libId) external view returns (bool);
    function depsLocked(bytes32 appId) external view returns (bool);
}
