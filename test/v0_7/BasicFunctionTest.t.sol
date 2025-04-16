// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { SuperPaymasterV0_7 } from "../../src/v0_7/SuperPaymasterV0_7.sol";
import { ISuperPaymaster } from "../../src/interfaces/ISuperPaymaster.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockEntryPoint } from "../mocks/MockEntryPoint.sol";

/**
 * Basic function tests for SuperPaymaster focusing on sponsor management
 */
contract BasicFunctionTest is Test {
    // Contracts
    SuperPaymasterV0_7 paymaster;
    MockEntryPoint entryPoint;
    MockERC20 token;

    // Addresses
    address owner;
    address manager;
    address sponsor;
    address sponsorSigner;
    address user;

    // Constants
    uint256 constant EXCHANGE_RATE = 1000; // 1000 tokens = 1 ETH
    uint256 constant SPONSOR_DEPOSIT = 10 ether;
    uint256 constant WARNING_THRESHOLD = 1 ether;

    function setUp() public {
        // Setup addresses
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        sponsor = makeAddr("sponsor");
        sponsorSigner = makeAddr("sponsorSigner");
        user = makeAddr("user");

        // Deploy mocks
        vm.startPrank(owner);
        entryPoint = new MockEntryPoint();
        token = new MockERC20("Test Token", "TST", 18);
        
        // Create signers array
        address[] memory signers = new address[](1);
        signers[0] = manager;
        
        // Deploy paymaster
        paymaster = new SuperPaymasterV0_7(
            address(entryPoint),
            owner,
            manager,
            signers
        );
        
        // Register sponsor in setup
        paymaster.registerSponsor(sponsor);
        vm.stopPrank();
        
        // Mint tokens for testing
        token.mint(user, 10000 * 10**18);
        token.mint(sponsor, 10000 * 10**18);
        
        // Fund accounts with ETH
        deal(sponsor, 100 ether);
        
        // Deposit stake in setup
        vm.prank(sponsor);
        paymaster.depositStake{value: 5 ether}();
    }

    function testRegisterSponsorFailsWhenAlreadyRegistered() public {
        // Try to register again, should fail
        vm.prank(owner);
        vm.expectRevert("SuperPaymaster: sponsor already registered");
        paymaster.registerSponsor(sponsor);
    }
    
    function testSponsorConfiguration() public {
        // Configure as sponsor
        vm.startPrank(sponsor);
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            WARNING_THRESHOLD,
            sponsorSigner
        );
        vm.stopPrank();
        
        // Verify configuration
        ISuperPaymaster.SponsorConfig memory config = paymaster.getSponsorConfig(sponsor);
        assertEq(config.token, address(token), "Token should be set correctly");
        assertEq(config.exchangeRate, EXCHANGE_RATE, "Exchange rate should be set correctly");
        assertEq(config.warningThreshold, WARNING_THRESHOLD, "Warning threshold should be set correctly");
        assertEq(config.signer, sponsorSigner, "Signer should be set correctly");
    }
    
    function testVerifyStakeDeposit() public {
        // Check stake amount after setup
        assertEq(paymaster.getSponsorStake(sponsor), 5 ether, "Stake should be 5 ether after setup");
    }
    
    function testWithdrawStake() public {
        // Only execute withdrawal, setup already did the deposit
        vm.prank(sponsor);
        paymaster.withdrawStake(2 ether);
        
        // Check stake decreased
        assertEq(paymaster.getSponsorStake(sponsor), 3 ether, "Stake should decrease after withdrawal request");
        
        // Get withdrawal info
        (uint256 amount, uint64 unlockTime, bool executed) = paymaster.getWithdrawalInfo(sponsor);
        
        // Verify withdrawal details
        assertEq(amount, 2 ether, "Withdrawal amount should be correct");
        assertTrue(unlockTime > block.timestamp, "Unlock time should be in the future");
        assertFalse(executed, "Withdrawal should not be executed yet");
    }
    
    function testERC20BalanceCheck() public {
        // Check ERC20 balance
        uint256 balance = paymaster.getERC20Balance(sponsor, address(token));
        assertEq(balance, 10000 * 10**18, "ERC20 balance should be correct");
        
        // Check non-existent balance
        uint256 nonExistentBalance = paymaster.getERC20Balance(makeAddr("nonExistent"), address(token));
        assertEq(nonExistentBalance, 0, "Non-existent balance should be 0");
    }
    
    function testEnableDisableSponsor() public {
        // Should be disabled by default
        ISuperPaymaster.SponsorConfig memory config = paymaster.getSponsorConfig(sponsor);
        assertFalse(config.isEnabled, "Sponsor should be disabled by default");
        
        // Enable sponsor
        vm.prank(sponsor);
        paymaster.enableSponsor(true);
        
        // Verify enabled
        config = paymaster.getSponsorConfig(sponsor);
        assertTrue(config.isEnabled, "Sponsor should be enabled");
        
        // Disable sponsor
        vm.prank(sponsor);
        paymaster.enableSponsor(false);
        
        // Verify disabled
        config = paymaster.getSponsorConfig(sponsor);
        assertFalse(config.isEnabled, "Sponsor should be disabled");
    }
} 