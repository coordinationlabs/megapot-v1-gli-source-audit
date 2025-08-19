// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import {IEntropy, EntropyStructs} from "@pythnetwork/entropy-sdk-solidity/IEntropy.sol";
import {IEntropyConsumer} from "@pythnetwork/entropy-sdk-solidity/IEntropyConsumer.sol";

/*
Only for testing purposes
*/

contract TestEntropy is IEntropy {
    function register(
        uint128 feeInWei,
        bytes32 commitment,
        bytes calldata commitmentMetadata,
        uint64 chainLength,
        bytes calldata uri
    ) external override {}

    function withdraw(uint128 amount) external override {}

    function request(
        address provider,
        bytes32 userCommitment,
        bool useBlockHash
    ) external payable override returns (uint64 assignedSequenceNumber) {
        return 0;
    }

    function requestWithCallback(
        address,
        bytes32 userRandomNumber
    ) external payable override returns (uint64 assignedSequenceNumber) {
        IEntropyConsumer consumer = IEntropyConsumer(msg.sender);
        consumer._entropyCallback(0, address(0), userRandomNumber);
        return 0;
    }

    function reveal(
        address provider,
        uint64 sequenceNumber,
        bytes32 userRevelation,
        bytes32 providerRevelation
    ) external override returns (bytes32 randomNumber) {
        return bytes32(0);
    }

    function revealWithCallback(
        address provider,
        uint64 sequenceNumber,
        bytes32 userRandomNumber,
        bytes32 providerRevelation
    ) external override {}

    function getProviderInfo(
        address provider
    )
        external
        view
        override
        returns (EntropyStructs.ProviderInfo memory info)
    {}

    function getDefaultProvider()
        external
        view
        override
        returns (address provider)
    {
        return address(this);
    }

    function getRequest(
        address provider,
        uint64 sequenceNumber
    ) external view override returns (EntropyStructs.Request memory req) {}

    function getFee(
        address
    ) external pure override returns (uint128 feeAmount) {
        return 100;
    }

    function getAccruedPythFees()
        external
        view
        override
        returns (uint128 accruedPythFeesInWei)
    {
        return 0;
    }

    function setProviderFee(uint128 newFeeInWei) external override {}

    function setProviderUri(bytes calldata newUri) external override {}

    function constructUserCommitment(
        bytes32 userRandomness
    ) external pure override returns (bytes32 userCommitment) {
        return bytes32(0);
    }

    function combineRandomValues(
        bytes32 userRandomness,
        bytes32 providerRandomness,
        bytes32 blockHash
    ) external pure override returns (bytes32 combinedRandomness) {
        return bytes32(0);
    }

    function setFeeManager(address manager) external override {}

    function setProviderFeeAsFeeManager(
        address provider,
        uint128 newFeeInWei
    ) external override {}

    function withdrawAsFeeManager(
        address provider,
        uint128 amount
    ) external override {}
}
