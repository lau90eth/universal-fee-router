// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/UniversalFeeRouter.sol";
import "../src/UniversalFeeRouterFactory.sol";

/**
 * @notice Deploys UniversalFeeRouterFactory and a set of canonical routers.
 *
 * Usage:
 *   # Dry run
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL -vvvv
 *
 *   # Broadcast
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL \
 *     --private-key $PRIVATE_KEY --broadcast --verify
 *
 * Environment variables:
 *   RPC_URL      — chain RPC endpoint
 *   PRIVATE_KEY  — deployer private key (without 0x prefix)
 *   ETHERSCAN_API_KEY — for contract verification
 */
contract Deploy is Script {

    // ── Canonical recipient placeholders ─────────────────────────────────────
    // Replace with real addresses before mainnet deploy

    address constant TREASURY   = 0x000000000000000000000000000000000000dEaD;
    address constant FRONTEND   = 0x000000000000000000000000000000000000dEaD;
    address constant PROTOCOL   = 0x000000000000000000000000000000000000dEaD;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        console.log("=== Universal Fee Router Deploy ===");
        console.log("Deployer:  ", deployer);
        console.log("Chain ID:  ", block.chainid);
        console.log("Balance:   ", deployer.balance);

        vm.startBroadcast(deployerKey);

        // ── 1. Deploy Factory ─────────────────────────────────────────────
        UniversalFeeRouterFactory factory = new UniversalFeeRouterFactory();
        console.log("Factory:   ", address(factory));

        // ── 2. Deploy canonical routers ───────────────────────────────────

        // 50/50
        UniversalFeeRouter.FeeSplit[] memory s5050 =
            new UniversalFeeRouter.FeeSplit[](2);
        s5050[0] = UniversalFeeRouter.FeeSplit(TREASURY, 5_000);
        s5050[1] = UniversalFeeRouter.FeeSplit(FRONTEND, 5_000);
        (address r5050,) = factory.deploy(s5050);
        console.log("50/50:     ", r5050);

        // 70/20/10
        UniversalFeeRouter.FeeSplit[] memory s702010 =
            new UniversalFeeRouter.FeeSplit[](3);
        s702010[0] = UniversalFeeRouter.FeeSplit(TREASURY,  7_000);
        s702010[1] = UniversalFeeRouter.FeeSplit(FRONTEND,  2_000);
        s702010[2] = UniversalFeeRouter.FeeSplit(PROTOCOL,  1_000);
        (address r702010,) = factory.deploy(s702010);
        console.log("70/20/10:  ", r702010);

        // 100% treasury
        UniversalFeeRouter.FeeSplit[] memory s100 =
            new UniversalFeeRouter.FeeSplit[](1);
        s100[0] = UniversalFeeRouter.FeeSplit(TREASURY, 10_000);
        (address r100,) = factory.deploy(s100);
        console.log("100%:      ", r100);

        vm.stopBroadcast();

        console.log("=== Deploy complete ===");
    }
}
