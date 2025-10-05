// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ILoan} from "../../interfaces/ILoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IVotingEscrow} from "../../interfaces/IVotingEscrow.sol";
import {IVoter} from "../../interfaces/IVoter.sol";
import {PortfolioFactory} from "../../accounts/PortfolioFactory.sol";
import {CollateralStorage} from "../../storage/CollateralStorage.sol";

/**
 * @title VelodromeFacet
 * @dev Middleware facet that interfaces with the loan contract
 */
contract VelodromeFacet {
    PortfolioFactory public immutable portfolioFactory;

    constructor(address _portfolioFactory) {
        require(_portfolioFactory != address(0));
        portfolioFactory = PortfolioFactory(_portfolioFactory);
    }

    function velodromeClaimCollateral(address loanContract, uint256 tokenId) external {
        ILoan(loanContract).claimCollateral(tokenId);
        address asset = address(ILoan(loanContract)._ve());
        (uint256 balance, address borrower) = ILoan(loanContract).getLoanDetails(tokenId);
        // ensure the token doesnt have a loan within the loan contract
        require(borrower == address(0) && balance == 0);
        IVotingEscrow(asset).transferFrom(address(this), msg.sender, tokenId);
        CollateralStorage.removeNonfungibleCollateral(asset, tokenId);
    }

    function velodromeIncreaseLoan(address loanContract, uint256 tokenId, uint256 amount) external {
        ILoan(loanContract).increaseLoan(tokenId, amount);
        address asset = address(ILoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);
    }
    
    function velodromeRequestLoan(address loanContract, uint256 tokenId, uint256 amount, ILoan.ZeroBalanceOption zeroBalanceOption, uint256 increasePercentage, address preferredToken, bool topUp, bool optInCommunityRewards) external {
        ILoan(loanContract).requestLoan(tokenId, amount, zeroBalanceOption, increasePercentage, preferredToken, topUp, optInCommunityRewards);
        address asset = address(ILoan(loanContract)._asset());
        IERC20(asset).transfer(msg.sender, amount);

        address ve = address(ILoan(loanContract)._ve());
        CollateralStorage.addNonfungibleCollateral(ve, tokenId);

    }

    function velodromeVote(address loanContract, uint256 tokenId) external returns (bool success) {
        address ve = address(ILoan(loanContract)._ve());
        IERC721(ve).setApprovalForAll(address(loanContract), true);
        success = ILoan(loanContract).vote(tokenId);
        IERC721(ve).setApprovalForAll(address(loanContract), false);
    }

    function velodromeUserVote(address loanContract, uint256[] calldata tokenIds, address[] calldata pools, uint256[] calldata weights) external {
        address ve = address(ILoan(loanContract)._ve());
        IERC721(ve).setApprovalForAll(address(loanContract), true);
        ILoan(loanContract).userVote(tokenIds, pools, weights);
        IERC721(ve).setApprovalForAll(address(loanContract), false);
    }

    function velodromeClaim(address loanContract, uint256 tokenId, address[] calldata fees, address[][] calldata tokens, bytes calldata tradeData, uint256[2] calldata allocations) external returns (uint256) {
        address ve = address(ILoan(loanContract)._ve());
        IERC721(ve).setApprovalForAll(address(loanContract), true);
        uint256 result = ILoan(loanContract).claim(tokenId, fees, tokens, tradeData, allocations);
        IERC721(ve).setApprovalForAll(address(loanContract), false);
        return result;
    }
}