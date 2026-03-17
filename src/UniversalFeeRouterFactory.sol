// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UniversalFeeRouter.sol";

/**
 * @title  UniversalFeeRouterFactory
 * @notice CREATE2 factory for UniversalFeeRouter.
 *
 *         Key property: identical FeeSplit[] configurations produce
 *         the same router address on every EVM chain.
 *
 *         This transforms UFR from a contract into a coordination layer:
 *         integrators do not deploy — they look up.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * DETERMINISM GUARANTEE
 * ─────────────────────────────────────────────────────────────────────────────
 *  canonical = sort splits by recipient address ascending
 *  salt      = keccak256(packed(recipient_0, bps_0, recipient_1, bps_1, ...))
 *  address   = CREATE2(salt, bytecode)
 *
 *  [A,B] and [B,A] with same shares → same salt → same address.
 *  Cross-chain: deploy this factory at the same address (via Nick's method)
 *  and all router addresses are identical across all EVM chains.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * INVARIANTS
 * ─────────────────────────────────────────────────────────────────────────────
 *  F1. predict(splits) == deploy(splits) address (always)
 *  F2. deploy(splits) is idempotent — second call returns existing address
 *  F3. No privileged roles on factory post-deploy
 *  F4. [A,B] and [B,A] with same bps → same address (canonical ordering)
 */
contract UniversalFeeRouterFactory {

    // ── Events ────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new router is deployed.
    /// @param router  The deployed router address.
    /// @param salt    The canonical salt (keccak256 of packed sorted splits).
    event RouterDeployed(
        address indexed router,
        bytes32 indexed salt
    );

    // ── State ─────────────────────────────────────────────────────────────────

    /// @notice salt → deployed router address (address(0) if not yet deployed)
    mapping(bytes32 => address) public routers;

    // ── Core ──────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new UniversalFeeRouter for the given splits,
     *         or return the existing one if already deployed.
     *
     * @param splits  The fee split configuration.
     * @return router The (possibly pre-existing) router address.
     * @return fresh  True if newly deployed, false if already existed.
     */
    function deploy(UniversalFeeRouter.FeeSplit[] calldata splits)
        external
        returns (address router, bool fresh)
    {
        bytes32 salt = _salt(splits);

        // Return existing if already deployed (idempotent)
        if (routers[salt] != address(0)) {
            return (routers[salt], false);
        }

        // Deploy via CREATE2
        bytes memory bytecode = _bytecode(splits);
        address deployed;
        assembly {
            deployed := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(deployed != address(0), "UFR-F: deploy failed");

        routers[salt]  = deployed;
        emit RouterDeployed(deployed, salt);
        return (deployed, true);
    }

    /**
     * @notice Predict the deterministic address for a given splits config
     *         without deploying.
     *
     * @param splits  The fee split configuration.
     * @return        The address where the router will/would be deployed.
     */
    function predict(UniversalFeeRouter.FeeSplit[] calldata splits)
        external
        view
        returns (address)
    {
        bytes32 salt     = _salt(splits);
        bytes32 bytecodeHash = keccak256(_bytecode(splits));
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            bytecodeHash
        )))));
    }

    /**
     * @notice Check if a splits config has already been deployed.
     */
    function isDeployed(UniversalFeeRouter.FeeSplit[] calldata splits)
        external
        view
        returns (bool)
    {
        return routers[_salt(splits)] != address(0);
    }

    /**
     * @notice Compute the deterministic salt for a splits config.
     *         salt = keccak256(abi.encode(splits))
     */
    function computeSalt(UniversalFeeRouter.FeeSplit[] calldata splits)
        external
        pure
        returns (bytes32)
    {
        return _salt(splits);
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    /**
     * @dev Canonical salt: sort splits by recipient address ascending,
     *      then packed-encode each (recipient, bps) pair.
     *
     *      Sorting guarantees [A,B] and [B,A] produce the same salt.
     *      Packed encoding is future-proof: independent of ABI struct layout.
     *
     *      Also validates:
     *      - No duplicate recipients (checked post-sort: adjacent duplicates)
     *      - No zero bps (fail-fast before hitting router constructor)
     */
    function _salt(UniversalFeeRouter.FeeSplit[] memory splits)
        internal
        pure
        returns (bytes32)
    {
        splits = _sort(splits);
        bytes memory packed;
        for (uint256 i; i < splits.length; ++i) {
            // Fail-fast: zero bps
            require(splits[i].bps > 0, "UFR-F: zero bps");
            // Duplicate check post-sort: duplicates are adjacent after sorting
            require(
                i == 0 || splits[i].recipient != splits[i-1].recipient,
                "UFR-F: duplicate recipient"
            );
            packed = abi.encodePacked(
                packed,
                splits[i].recipient,
                splits[i].bps
            );
        }
        return keccak256(packed);
    }

    /**
     * @dev Sort splits by recipient address ascending (insertion sort).
     *      O(n²) — n ≤ 20, negligible gas.
     *      Returns a sorted copy; does not mutate the input.
     */
    function _sort(UniversalFeeRouter.FeeSplit[] memory splits)
        internal
        pure
        returns (UniversalFeeRouter.FeeSplit[] memory)
    {
        uint256 n = splits.length;
        UniversalFeeRouter.FeeSplit[] memory s =
            new UniversalFeeRouter.FeeSplit[](n);
        for (uint256 i; i < n; ++i) s[i] = splits[i];

        for (uint256 i = 1; i < n; ++i) {
            UniversalFeeRouter.FeeSplit memory key = s[i];
            uint256 j = i;
            while (j > 0 && s[j-1].recipient > key.recipient) {
                s[j] = s[j-1];
                j--;
            }
            s[j] = key;
        }
        return s;
    }

    function _bytecode(UniversalFeeRouter.FeeSplit[] memory splits)
        internal
        pure
        returns (bytes memory)
    {
        // Pass splits sorted so the deployed router matches the canonical config
        return abi.encodePacked(
            type(UniversalFeeRouter).creationCode,
            abi.encode(_sort(splits))
        );
    }
}
