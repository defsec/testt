// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {Loan} from "../src/LoanV2.sol";
import {AerodromeFacet} from "../src/facets/account/AerodromeFacet.sol";
import {ILoan} from "../src/interfaces/ILoan.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IVoter} from "src/interfaces/IVoter.sol";
import {Vault} from "src/VaultV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProtocolTimeLibrary} from "src/libraries/ProtocolTimeLibrary.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {BaseDeploy} from "../script/BaseDeploy.s.sol";
import {BaseUpgrade} from "../script/BaseUpgrade.s.sol";
import {DeploySwapper} from "../script/BaseDeploySwapper.s.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ICLGauge} from "src/interfaces/ICLGauge.sol";
import {Swapper} from "../src/Swapper.sol";
import {CommunityRewards} from "../src/CommunityRewards/CommunityRewards.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {PortfolioFactory} from "../src/accounts/PortfolioFactory.sol";
import {FacetRegistry} from "../src/accounts/FacetRegistry.sol";

contract MockOdosRouterRL {
    address public testContract;

    address ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    address USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    
    function initMock(address _testContract) external { testContract = _testContract; }
    function executeSwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut) external returns (bool) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", address(this), msg.sender, amountOut));
        require(success, "mint fail");
        return true;
    }


    function executeSwapMultiOutput(uint256 amount1, uint256 amount2) external returns (bool) {
        (bool success,) = testContract.call(abi.encodeWithSignature("mintUsdc(address,address,uint256)", address(this), msg.sender, amount1));
        require(success, "mint fail");

        (bool success2,) = testContract.call(abi.encodeWithSignature("mintAero(address,uint256)", msg.sender, amount2));
        require(success2, "mint rex fail");

        return true;
    }
}

interface IUSDC {
    function balanceOf(address account) external view returns (uint256);
    function mint(address to, uint256 amount) external;
    function configureMinter(
        address minter,
        uint256 minterAllowedAmount
    ) external;
    function masterMinter() external view returns (address);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function acceptOwnership() external;
}

/**
 * @title AerodromeTest
 * @dev Test contract for DiamondAccount Loan facet functionality
 */
contract AerodromeTest is Test {
    uint256 fork;

    address ODOS = 0x19cEeAd7105607Cd444F5ad10dd51356436095a1;
    IERC20 aero = IERC20(0x940181a94A35A4569E4529A3CDfB74e38FD98631);
    IUSDC usdc = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    IVotingEscrow votingEscrow =
        IVotingEscrow(0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4);
    IERC20 weth = IERC20(0x4200000000000000000000000000000000000006);
    IVoter public voter = IVoter(0x16613524e02ad97eDfeF371bC883F2F5d6C480A5);
    address[] pool = [address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59)];
    ProxyAdmin admin;

    // deployed contracts
    Vault vault;
    Loan public loan;
    AerodromeFacet public loanFacet;
    address owner;
    address user;
    uint256 tokenId = 64196;

    uint256 expectedRewards = 957174473;

    Swapper public swapper;

    // Account Factory system
    PortfolioFactory public portfolioFactory;

    function setUp() public {
        fork = vm.createFork(vm.envString("ETH_RPC_URL"));
        vm.selectFork(fork);
        vm.rollFork(24353746);
        owner = vm.addr(0x123);
        user = votingEscrow.ownerOf(tokenId);
        BaseDeploy deployer = new BaseDeploy();
        (loan, vault) = deployer.deployLoan();

        // Deploy Account Factory system
        _deployPortfolioFactory();

        vm.startPrank(address(deployer));
        loan.setMultiplier(100000000000);
        loan.setRewardsRate(11300);
        loan.setLenderPremium(2000);
        loan.setProtocolFee(500); // 5% protocol fee
        IOwnable(address(loan)).transferOwnership(owner);
        DeploySwapper swapperDeploy = new DeploySwapper();
        swapper = Swapper(swapperDeploy.deploy());
        loan.setSwapper(address(swapper));
        loan.setPortfolioFactory(address(portfolioFactory));
        vm.stopPrank();

        vm.startPrank(owner);
        IOwnable(address(loan)).acceptOwnership();

        // Approve the pool for voting
        address[] memory pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        loan.setApprovedPools(pools, true);
        
        vm.stopPrank();

        // Deploy the AerodromeFacet
        loanFacet = new AerodromeFacet(address(portfolioFactory));

        // Register AerodromeFacet in the FacetRegistry
        bytes4[] memory loanSelectors = new bytes4[](6);
        loanSelectors[0] = 0xd3f8e227; // aerodromeRequestLoan(address,uint256,uint256,uint8,uint256,address,bool,bool)
        loanSelectors[1] = 0x68f84e48; // aerodromeIncreaseLoan(address,uint256,uint256)
        loanSelectors[2] = 0x5780b3ee; // aerodromeClaimCollateral(address,uint256)
        loanSelectors[3] = 0xfbb66d95; // aerodromeVote(address,uint256)
        loanSelectors[4] = 0xe8b820ba; // aerodromeUserVote(address,uint256[],address[],uint256[])
        loanSelectors[5] = 0xd69af01c; // aerodromeClaim(address,uint256,address[],address[][],bytes,uint256[2])

        // Get the FacetRegistry from the PortfolioFactory
        FacetRegistry facetRegistry = FacetRegistry(
            portfolioFactory.facetRegistry()
        );
        facetRegistry.registerFacet(
            address(loanFacet),
            loanSelectors,
            "AerodromeFacet"
        );

        // allow this test contract to mint USDC
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(voter), 100e6);
        usdc.mint(address(vault), 100e6);
        MockOdosRouterRL mock = new MockOdosRouterRL();
        bytes memory code = address(mock).code;
        vm.etch(ODOS, code);
        MockOdosRouterRL(ODOS).initMock(address(this));
        vm.prank(0x7269de76188E6597444D0859C4e5c336D3c39dDb);
        IERC20(aero).transfer(address(this), 10000e18);
    }

    function _deployPortfolioFactory() internal {
        // Deploy FacetRegistry
        FacetRegistry facetRegistry = new FacetRegistry();

        // Deploy PortfolioFactory
        portfolioFactory = new PortfolioFactory(
            address(facetRegistry)
        );

    }

    // helper for mock to mint USDC to a recipient
    function mintUsdc(address /*minter*/, address to, uint256 amount) external {
        console.log("mintUsdc", to, amount);
        usdc.mint(to, amount);
    }

    // helper for mock to mint REX to a recipient
    function mintAero(address to, uint256 amount) external {
        console.log("mintAero", to, amount);
        console.log("aero balance before:", aero.balanceOf(address(this)));
        aero.transfer(to, amount);
        console.log("aero transfer successful");
    }

    function testOwner() public view {
        address o = loan.owner();
        assertEq(o, owner);
    }

    function testNftOwner() public view {
        assertEq(votingEscrow.ownerOf(tokenId), address(user));
    }

    /**
     * @dev Test the getMaxLoan functionality through the AerodromeFacet
     * This replicates the testGetMaxLoan test from LoanTest but uses the AerodromeFacet
     */
    function testGetMaxLoan() public {
        // Test initial max loan through the facet
        (uint256 maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 80e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            
            vm.startPrank(user); // Resume user prank
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        // log users _asset balance
        uint256 userAssetBalance = IERC20(loan._asset()).balanceOf(user);
        vm.startPrank(user);
        uint256 amount = 5e6;
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );

        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + amount
        );

        // the tokenId should be owned by the user account after requesting a loan
        assertEq(votingEscrow.ownerOf(tokenId), address(userAccount));

        // Test max loan after requesting a loan through the facet
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 75e6);

        // Test max loan after increasing loan through the direct contract
        AerodromeFacet(userAccount).aerodromeIncreaseLoan(address(loan), tokenId, 70e6);
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6
        );

        // Test max loan after maxing out the loan through the direct contract
        AerodromeFacet(userAccount).aerodromeIncreaseLoan(address(loan), tokenId, 5e6);
        // ensure users asset increased by loan amount
        assertEq(
            IERC20(loan._asset()).balanceOf(user),
            userAssetBalance + 5e6 + 70e6 + 5e6
        );
        (maxLoan, ) = loan.getMaxLoan(tokenId);
        assertEq(maxLoan, 0);
        vm.stopPrank();
    }

    /**
     * @dev Test loan request through the facet
     */
    function testLoanRequest() public {
        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank

            vm.startPrank(user); // Resume user prank
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        uint256 amount = 1e6;
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();

        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertTrue(usdc.balanceOf(address(vault)) < 100e6);

        // Verify the loan details through the facet
        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, address(userAccount));

        // Verify the NFT ownership - should be owned by user account after requesting loan
        assertEq(votingEscrow.ownerOf(tokenId), address(userAccount));
    }

    /**
     * @dev Test loan increase through the facet
     */
    function testIncreaseLoan() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            vm.startPrank(user); // Resume user prank
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.roll(block.number + 1);
        loan.vote(tokenId);
        vm.stopPrank();

        assertTrue(usdc.balanceOf(address(user)) > 1e6);
        assertEq(loan.activeAssets(), 1e6);

        (uint256 balance, address borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, address(userAccount));

        // Test increasing the loan through the facet
        vm.startPrank(user);
        AerodromeFacet(userAccount).aerodromeIncreaseLoan(address(loan), tokenId, amount);
        vm.stopPrank();

        (balance, borrower) = loan.getLoanDetails(tokenId);
        assertTrue(balance > amount);
        assertEq(borrower, address(userAccount));
        assertEq(loan.activeAssets(), 2e6);

        assertEq(usdc.balanceOf(address(user)), 2e6 + startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 98e6);
    }

    /**
     * @dev Test vote functionality
     */
    function testVote() public {
        uint256 amount = 1e6;

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);
            vm.stopPrank();
            vm.startPrank(user);
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();

        // set user to auto vote
        vm.startPrank(user);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        address[] memory pools = new address[](0);
        uint256[] memory weights = new uint256[](0);
        AerodromeFacet(userAccount).aerodromeUserVote(
            address(loan),
            tokenIds,
            pools,
            weights
        );
        vm.stopPrank();

        // warp time to the last day of the epoch
        vm.roll(block.number + 1);
        vm.warp(1758751302);
        vm.startPrank(user);
        vm.stopPrank();
        bool voteResult = AerodromeFacet(userAccount).aerodromeVote(address(loan), tokenId);

        // Verify that vote was successful
        assertTrue(voteResult, "Vote should have been successful");
    }

    /**
     * @dev Test userVote functionality
     */
    function testUserVote() public {
        uint256 amount = 1e6;

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);
            vm.stopPrank();
            vm.startPrank(user);
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();

        // Test userVote function with empty arrays (resets to automatic voting)
        vm.startPrank(user);
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        address[] memory pools = new address[](0);
        uint256[] memory weights = new uint256[](0);
        AerodromeFacet(userAccount).aerodromeUserVote(
            address(loan),
            tokenIds,
            pools,
            weights
        );
        vm.stopPrank();

        // fast forward one week and one block
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1 weeks);
        // get the weight of tokenId

        // Test userVote function with actual pools and weights
        vm.startPrank(user);
        pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        weights = new uint256[](1);
        weights[0] = 100e18; // 100% weight
        AerodromeFacet(userAccount).aerodromeUserVote(
            address(loan),
            tokenIds,
            pools,
            weights
        );
        vm.stopPrank();
    }

    /**
     * @dev Test loan payoff through the facet
     */
    function testLoanPayoff() public {
        vm.prank(usdc.masterMinter());
        usdc.configureMinter(address(this), type(uint256).max);
        usdc.mint(address(user), 100e6);
        vm.stopPrank();

        uint256 amount = 1e6;
        assertEq(votingEscrow.ownerOf(tokenId), address(user));

        uint256 startingUserBalance = usdc.balanceOf(address(user));
        assertEq(usdc.balanceOf(address(user)), startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 100e6);

        // user deposits the NFT to their account
        vm.startPrank(user);
        // approve AssetFacet to transfer the NFT
        address userAccount = portfolioFactory.getUserAccount(user);
        // create the user account if it doesn't exist
        if (userAccount == address(0)) {
            portfolioFactory.createAccount(user);
            userAccount = portfolioFactory.getAccount(user);

            // Authorize the user account to call CollateralStorage
            vm.stopPrank(); // Stop current prank
            vm.startPrank(user); // Resume user prank
        }

        IERC721(address(votingEscrow)).transferFrom(
            user,
            address(userAccount),
            tokenId
        );
        vm.stopPrank();

        vm.startPrank(user);
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.DoNothing,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(user)), 1e6 + startingUserBalance);
        assertEq(usdc.balanceOf(address(vault)), 99e6);
        assertEq(votingEscrow.ownerOf(tokenId), address(userAccount));

        // Test payoff through the facet
        vm.startPrank(user);
        usdc.approve(address(loan), 5e6);
        loan.pay(tokenId, 0);

        assertEq(votingEscrow.ownerOf(tokenId), address(userAccount));

        AerodromeFacet(userAccount).aerodromeClaimCollateral(address(loan), tokenId);

        assertEq(votingEscrow.ownerOf(tokenId), address(user));
        vm.stopPrank();
    }

    function testClaim() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            userAccount = portfolioFactory.createAccount(user);
        }

        // Transfer NFT to user account
        votingEscrow.transferFrom(user, userAccount, tokenId);
        vm.stopPrank();

        // Request loan through the user account
        vm.startPrank(user);
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.PayToOwner,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();

        // Verify loan was created
        (uint256 balance, ) = loan.getLoanDetails(tokenId);
        assertTrue(
            balance >= amount,
            "Loan balance should be at least the requested amount"
        );

        // Verify the user received the loan
        uint256 endingUserBalance = usdc.balanceOf(address(user));
        assertTrue(
            endingUserBalance > startingUserBalance,
            "User should have received loan funds"
        );

        // Test that the user account can interact with the loan
        vm.startPrank(user);

        // Test that the user account can vote (this tests the user account integration)
        address[] memory pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000; // 100 tokens

        // This should work through the user account
        AerodromeFacet(userAccount).aerodromeUserVote(
            address(loan),
            new uint256[](0), // no tokenIds for auto-vote
            pools,
            weights
        );
        vm.stopPrank();

        // Verify the vote was recorded
        address votedPool = voter.poolVote(tokenId, 0);
        assertEq(votedPool, pools[0], "Pool should be voted for");

        console.log("User account integration test passed");
        console.log("Loan balance:", balance);
        console.log(
            "User USDC balance change:",
            endingUserBalance - startingUserBalance
        );

        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);
        uint256[2] memory allocations = [
            uint256(100e6),
            uint256(21919478169541)
        ];

        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapMultiOutput.selector,
            100e6,
            21919478169540 // send less to account for slippage
        );
        uint256 rewards = _claimRewards(
            Loan(userAccount),
            tokenId,
            bribes,
            tradeData,
            allocations
        );

        // loan balance should be 0
        ( balance, ) = loan.getLoanDetails(tokenId);
        assertEq(balance, 0, "Balance should be 0");
    }

    // test claims without transferring the NFT to the user account
    function testClaim2() public {
        uint256 amount = 1e6;
        uint256 startingUserBalance = usdc.balanceOf(address(user));

        // user deposits the NFT to their account
        vm.startPrank(user);
        address userAccount = portfolioFactory.getUserAccount(user);
        if (userAccount == address(0)) {
            userAccount = portfolioFactory.createAccount(user);
        }

        // Transfer NFT to user account
        vm.stopPrank();

        int128 beginningNftLockedAmount = votingEscrow.locked(tokenId).amount;
        // Request loan through the user account
        vm.startPrank(user);
        IERC721(address(votingEscrow)).approve(address(userAccount), tokenId);
        AerodromeFacet(userAccount).aerodromeRequestLoan(
            address(loan),
            tokenId,
            amount,
            ILoan.ZeroBalanceOption.PayToOwner,
            0,
            address(0),
            false,
            false
        );
        vm.stopPrank();

        // Verify loan was created
        (uint256 balance, ) = loan.getLoanDetails(tokenId);
        assertTrue(
            balance >= amount,
            "Loan balance should be at least the requested amount"
        );

        // Verify the user received the loan
        uint256 endingUserBalance = usdc.balanceOf(address(user));
        assertTrue(
            endingUserBalance > startingUserBalance,
            "User should have received loan funds"
        );

        // Test that the user account can interact with the loan
        vm.startPrank(user);

        // Test that the user account can vote (this tests the user account integration)
        address[] memory pools = new address[](1);
        pools[0] = address(0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 100000000000000000000; // 100 tokens

        // This should work through the user account
        AerodromeFacet(userAccount).aerodromeUserVote(
            address(loan),
            new uint256[](0), // no tokenIds for auto-vote
            pools,
            weights
        );
        vm.stopPrank();

        // Verify the vote was recorded
        address votedPool = voter.poolVote(tokenId, 0);
        assertEq(votedPool, pools[0], "Pool should be voted for");

        console.log("User account integration test passed");
        console.log("Loan balance:", balance);
        console.log(
            "User USDC balance change:",
            endingUserBalance - startingUserBalance
        );

        uint256 beginningUserUsdcBalance = usdc.balanceOf(address(user));
        address[] memory bribes = new address[](0);

        uint256[2] memory allocations = [
            uint256(100e6),
            uint256(21919478169541)
        ];

        bytes memory tradeData = abi.encodeWithSelector(
            MockOdosRouterRL.executeSwapMultiOutput.selector,
            100e6,
            21919478169540 // send less to account for slippage
        );
        uint256 rewards = _claimRewards(
            Loan(userAccount),
            tokenId,
            bribes,
            tradeData,
            allocations
        );
        // loan balance should be 0
        ( balance, ) = loan.getLoanDetails(tokenId);
        assertEq(balance, 0, "Balance should be 0");

        int128 endingNftLockedAmount = votingEscrow.locked(tokenId).amount;
        console.log("endingNftLockedAmount", endingNftLockedAmount);
        console.log("beginningNftLockedAmount", beginningNftLockedAmount);
        assertTrue(endingNftLockedAmount >= beginningNftLockedAmount + 21919478169540, "NFT locked amount should increase");
    }

    function _claimRewards(
        Loan _loan,
        uint256 _tokenId,
        address[] memory bribes,
        bytes memory tradeData,
        uint256[2] memory allocations
    ) internal returns (uint256) {
        address[] memory pools = new address[](256); // Assuming a maximum of 256 pool votes
        uint256 index = 0;

        while (true) {
            try voter.poolVote(_tokenId, index) returns (address _pool) {
                pools[index] = _pool;
                index++;
            } catch {
                break; // Exit the loop when it reverts
            }
        }

        address[] memory voterPools = new address[](index);
        for (uint256 i = 0; i < index; i++) {
            voterPools[i] = pools[i];
        }
        address[] memory fees = new address[](2 * voterPools.length);
        address[][] memory tokens = new address[][](2 * voterPools.length);

        for (uint256 i = 0; i < voterPools.length; i++) {
            address gauge = voter.gauges(voterPools[i]);
            fees[2 * i] = voter.gaugeToFees(gauge);
            fees[2 * i + 1] = voter.gaugeToBribe(gauge);
            address[] memory token = new address[](2);
            token[0] = ICLGauge(voterPools[i]).token0();
            token[1] = ICLGauge(voterPools[i]).token1();
            tokens[2 * i] = token;
            address[] memory bribeTokens = new address[](bribes.length + 2);
            for (uint256 j = 0; j < bribes.length; j++) {
                bribeTokens[j] = bribes[j];
            }
            bribeTokens[bribes.length] = token[0];
            bribeTokens[bribes.length + 1] = token[1];
            tokens[2 * i + 1] = bribeTokens;
        }
        bytes memory data = "";  
        vm.startPrank(0x40AC2E93d1257196a418fcE7D6eDAcDE65aAf2BA);
        uint256 result = AerodromeFacet(address(_loan)).aerodromeClaim(
            address(loan), // Use the actual loan contract address
            _tokenId,
            fees,
            tokens,
            tradeData,
            allocations
        );
        vm.stopPrank();
        return result;
    }
}
