// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// Token
import {BTB} from "../src/token/BTB.sol";

// Core V2
import {Pool} from "../src/core/Pool.sol";
import {PoolFactory} from "../src/core/PoolFactory.sol";

// Core CL
import {CLPool} from "../src/core/CLPool.sol";
import {CLFactory} from "../src/core/CLFactory.sol";

// Governance
import {VotingEscrow} from "../src/governance/VotingEscrow.sol";
import {Voter} from "../src/governance/Voter.sol";
import {Minter} from "../src/governance/Minter.sol";
import {RewardsDistributor} from "../src/governance/RewardsDistributor.sol";

// Periphery
import {Router} from "../src/periphery/Router.sol";
import {CLRouter} from "../src/periphery/CLRouter.sol";

/// @title BTB Finance Deployment Script
/// @notice Deploys all BTB Finance DEX contracts
contract DeployBTBFinance is Script {
    // Deployed contract addresses
    address public btb;
    address public poolImplementation;
    address public poolFactory;
    address public clPoolImplementation;
    address public clFactory;
    address public votingEscrow;
    address public voter;
    address public minter;
    address public rewardsDistributor;
    address public router;
    address public clRouter;

    // Configuration
    address public weth;
    address public deployer;

    function run() external {
        // Load config from environment
        weth = vm.envAddress("WETH_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerKey);

        console.log("Deploying BTB Finance DEX");
        console.log("Deployer:", deployer);
        console.log("WETH:", weth);

        vm.startBroadcast(deployerKey);

        // 1. Deploy BTB Token
        _deployBTB();

        // 2. Deploy V2 Pools
        _deployV2();

        // 3. Deploy CL Pools
        _deployCL();

        // 4. Deploy Governance
        _deployGovernance();

        // 5. Deploy Periphery (Routers)
        _deployPeriphery();

        // 6. Configure permissions
        _configure();

        vm.stopBroadcast();

        // Log all addresses
        _logAddresses();
    }

    function _deployBTB() internal {
        console.log("\n=== Deploying BTB Token ===");

        // Deploy implementation
        BTB btbImpl = new BTB();
        console.log("BTB Implementation:", address(btbImpl));

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(
            BTB.initialize.selector,
            deployer, // owner
            deployer  // initial minter (will be changed to Minter contract)
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(btbImpl), initData);
        btb = address(proxy);
        console.log("BTB Proxy:", btb);
    }

    function _deployV2() internal {
        console.log("\n=== Deploying V2 Pools ===");

        // Deploy Pool implementation
        poolImplementation = address(new Pool());
        console.log("Pool Implementation:", poolImplementation);

        // Deploy PoolFactory implementation
        PoolFactory factoryImpl = new PoolFactory();
        console.log("PoolFactory Implementation:", address(factoryImpl));

        // Deploy PoolFactory proxy
        bytes memory initData = abi.encodeWithSelector(
            PoolFactory.initialize.selector,
            poolImplementation,
            address(0) // voter - set later
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        poolFactory = address(proxy);
        console.log("PoolFactory Proxy:", poolFactory);
    }

    function _deployCL() internal {
        console.log("\n=== Deploying CL Pools ===");

        // Deploy CLPool implementation
        clPoolImplementation = address(new CLPool());
        console.log("CLPool Implementation:", clPoolImplementation);

        // Deploy CLFactory implementation
        CLFactory factoryImpl = new CLFactory();
        console.log("CLFactory Implementation:", address(factoryImpl));

        // Deploy CLFactory proxy
        bytes memory initData = abi.encodeWithSelector(
            CLFactory.initialize.selector,
            clPoolImplementation
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(factoryImpl), initData);
        clFactory = address(proxy);
        console.log("CLFactory Proxy:", clFactory);
    }

    function _deployGovernance() internal {
        console.log("\n=== Deploying Governance ===");

        // Deploy VotingEscrow implementation
        VotingEscrow veImpl = new VotingEscrow();
        console.log("VotingEscrow Implementation:", address(veImpl));

        // Deploy VotingEscrow proxy (voter set later)
        bytes memory veInitData = abi.encodeWithSelector(
            VotingEscrow.initialize.selector,
            btb,
            address(0) // voter - set later
        );
        ERC1967Proxy veProxy = new ERC1967Proxy(address(veImpl), veInitData);
        votingEscrow = address(veProxy);
        console.log("VotingEscrow Proxy:", votingEscrow);

        // Deploy Voter
        voter = address(new Voter(votingEscrow, btb));
        console.log("Voter:", voter);

        // Deploy RewardsDistributor
        rewardsDistributor = address(new RewardsDistributor(votingEscrow));
        console.log("RewardsDistributor:", rewardsDistributor);

        // Deploy Minter
        minter = address(new Minter(voter, votingEscrow, rewardsDistributor));
        console.log("Minter:", minter);
    }

    function _deployPeriphery() internal {
        console.log("\n=== Deploying Periphery ===");

        // Deploy V2 Router
        router = address(new Router(poolFactory, weth));
        console.log("Router (V2):", router);

        // Deploy CL Router
        clRouter = address(new CLRouter(clFactory, weth));
        console.log("CLRouter:", clRouter);
    }

    function _configure() internal {
        console.log("\n=== Configuring Permissions ===");

        // Set BTB minter to Minter contract
        BTB(btb).setMinter(minter);
        console.log("BTB minter set to Minter");

        // Set voter in PoolFactory
        PoolFactory(poolFactory).setVoter(voter);
        console.log("PoolFactory voter set");
    }

    function _logAddresses() internal view {
        console.log("\n========================================");
        console.log("BTB Finance DEX Deployment Complete!");
        console.log("========================================");
        console.log("");
        console.log("Token:");
        console.log("  BTB:", btb);
        console.log("");
        console.log("Core V2:");
        console.log("  Pool Implementation:", poolImplementation);
        console.log("  PoolFactory:", poolFactory);
        console.log("");
        console.log("Core CL:");
        console.log("  CLPool Implementation:", clPoolImplementation);
        console.log("  CLFactory:", clFactory);
        console.log("");
        console.log("Governance:");
        console.log("  VotingEscrow:", votingEscrow);
        console.log("  Voter:", voter);
        console.log("  Minter:", minter);
        console.log("  RewardsDistributor:", rewardsDistributor);
        console.log("");
        console.log("Periphery:");
        console.log("  Router (V2):", router);
        console.log("  CLRouter:", clRouter);
        console.log("========================================");
    }
}
