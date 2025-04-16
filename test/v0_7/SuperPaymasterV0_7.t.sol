// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";

import { SuperPaymasterV0_7 } from "../../src/v0_7/SuperPaymasterV0_7.sol";
import { ISuperPaymaster } from "../../src/interfaces/ISuperPaymaster.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockEntryPoint } from "../mocks/MockEntryPoint.sol";

contract SuperPaymasterV0_7Test is Test {
    // Contracts
    SuperPaymasterV0_7 public paymaster;
    MockEntryPoint public entryPoint;
    MockERC20 public token;

    // Addresses
    address public owner;
    address public manager;
    address public sponsorSigner;
    address public sponsor;
    address public user;
    address public bundler;

    // Test constants
    uint256 public constant EXCHANGE_RATE = 1000; // 1000 tokens = 1 ETH
    uint256 public constant SPONSOR_DEPOSIT = 10 ether;
    uint256 public constant WARNING_THRESHOLD = 1 ether;
    uint256 public constant TEST_WITHDRAWAL_DELAY = 10 minutes; // Shorter delay for testing

    function setUp() public {
        // Setup addresses
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        sponsor = makeAddr("sponsor");
        sponsorSigner = makeAddr("sponsorSigner");
        user = makeAddr("user");
        bundler = makeAddr("bundler");

        // Deploy mock contracts
        vm.startPrank(owner);
        entryPoint = new MockEntryPoint();
        token = new MockERC20("Test Token", "TST", 18);
        
        // Setup signers for the paymaster
        address[] memory signers = new address[](1);
        signers[0] = manager;
        
        // Deploy paymaster
        paymaster = new SuperPaymasterV0_7(
            address(entryPoint),
            owner,
            manager,
            signers
        );
        
        // Set withdrawal delay for testing
        paymaster.setWithdrawalDelay(TEST_WITHDRAWAL_DELAY);
        
        // Allow bundler
        paymaster.addBundler(bundler);
        vm.stopPrank();

        // Setup token and ETH balances
        deal(sponsor, 100 ether);
        token.mint(user, 1000 * 10**18);
    }

    function testRegisterSponsor() public {
        vm.prank(owner);
        paymaster.registerSponsor(sponsor);
        
        assertTrue(paymaster.isSponsor(sponsor), "Sponsor registration failed");
        
        ISuperPaymaster.SponsorConfig memory config = paymaster.getSponsorConfig(sponsor);
        assertEq(config.owner, sponsor, "Sponsor owner not set correctly");
        assertEq(config.isEnabled, false, "Sponsor should be disabled by default");
    }

    function testSponsorConfiguration() public {
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(sponsor);
        
        // Configure sponsor
        vm.prank(sponsor);
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            WARNING_THRESHOLD,
            sponsorSigner
        );
        
        // Verify configuration
        ISuperPaymaster.SponsorConfig memory config = paymaster.getSponsorConfig(sponsor);
        assertEq(config.token, address(token), "Token not set correctly");
        assertEq(config.exchangeRate, EXCHANGE_RATE, "Exchange rate not set correctly");
        assertEq(config.warningThreshold, WARNING_THRESHOLD, "Warning threshold not set correctly");
        assertEq(config.signer, sponsorSigner, "Signer not set correctly");
        
        // Enable sponsor
        vm.prank(sponsor);
        paymaster.enableSponsor(true);
        
        config = paymaster.getSponsorConfig(sponsor);
        assertTrue(config.isEnabled, "Sponsor should be enabled");
    }

    function testDepositStake() public {
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(sponsor);
        
        // Deposit stake
        vm.prank(sponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // Check stake amount
        assertEq(paymaster.getSponsorStake(sponsor), SPONSOR_DEPOSIT, "Deposit amount incorrect");
    }
    
    function testWithdrawalRequestLocking() public {
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(sponsor);
        
        // Deposit stake
        vm.prank(sponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // Request withdrawal
        vm.prank(sponsor);
        paymaster.withdrawStake(1 ether);
        
        // Check stake amount is decreased immediately
        assertEq(paymaster.getSponsorStake(sponsor), SPONSOR_DEPOSIT - 1 ether, "Stake amount not decreased after withdrawal request");
        
        // Get withdrawal ID (should be 0 as it's the first withdrawal)
        uint256 withdrawalId = 0;
        
        // Check withdrawal request details
        (uint256 amount, uint256 unlockTime, bool executed) = paymaster.getPendingWithdrawal(sponsor, withdrawalId);
        
        assertEq(amount, 1 ether, "Withdrawal amount incorrect");
        assertEq(unlockTime, block.timestamp + TEST_WITHDRAWAL_DELAY, "Unlock time incorrect");
        assertFalse(executed, "Withdrawal should not be executed yet");
        
        // Try to execute withdrawal before time lock expires (should fail)
        vm.prank(sponsor);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterV0_7.WithdrawalStillLocked.selector, unlockTime));
        paymaster.executeWithdrawal(withdrawalId);
        
        // Advance time past the lock period
        vm.warp(block.timestamp + TEST_WITHDRAWAL_DELAY + 1);
        
        // Execute withdrawal
        vm.prank(sponsor);
        paymaster.executeWithdrawal(withdrawalId);
        
        // Check withdrawal is marked as executed
        (,, executed) = paymaster.getPendingWithdrawal(sponsor, withdrawalId);
        assertTrue(executed, "Withdrawal should be marked as executed");
        
        // Try to execute again (should fail)
        vm.prank(sponsor);
        vm.expectRevert(SuperPaymasterV0_7.WithdrawalAlreadyExecuted.selector);
        paymaster.executeWithdrawal(withdrawalId);
    }
    
    function testWithdrawalCancellation() public {
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(sponsor);
        
        // Deposit stake
        vm.prank(sponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // Request withdrawal
        vm.prank(sponsor);
        paymaster.withdrawStake(2 ether);
        
        // Check stake amount is decreased
        assertEq(paymaster.getSponsorStake(sponsor), SPONSOR_DEPOSIT - 2 ether, "Stake amount not decreased after withdrawal request");
        
        // Get withdrawal ID (should be 0 as it's the first withdrawal)
        uint256 withdrawalId = 0;
        
        // Cancel the withdrawal
        vm.prank(sponsor);
        paymaster.cancelWithdrawal(withdrawalId);
        
        // Check stake amount is restored
        assertEq(paymaster.getSponsorStake(sponsor), SPONSOR_DEPOSIT, "Stake amount not restored after cancellation");
        
        // Check withdrawal is marked as executed
        (,, bool executed) = paymaster.getPendingWithdrawal(sponsor, withdrawalId);
        assertTrue(executed, "Withdrawal should be marked as executed on cancellation");
        
        // Try to execute the cancelled withdrawal (should fail)
        vm.warp(block.timestamp + TEST_WITHDRAWAL_DELAY + 1);
        vm.prank(sponsor);
        vm.expectRevert(SuperPaymasterV0_7.WithdrawalAlreadyExecuted.selector);
        paymaster.executeWithdrawal(withdrawalId);
    }
    
    function testMultipleWithdrawals() public {
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(sponsor);
        
        // Deposit stake
        vm.prank(sponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // Request first withdrawal
        vm.prank(sponsor);
        paymaster.withdrawStake(1 ether);
        
        // Request second withdrawal
        vm.prank(sponsor);
        paymaster.withdrawStake(2 ether);
        
        // Check stake amount is decreased for both
        assertEq(paymaster.getSponsorStake(sponsor), SPONSOR_DEPOSIT - 3 ether, "Stake amount incorrect after multiple withdrawals");
        
        // Get withdrawal IDs
        uint256 firstWithdrawalId = 0;
        uint256 secondWithdrawalId = 1;
        
        // Advance time past the lock period
        vm.warp(block.timestamp + TEST_WITHDRAWAL_DELAY + 1);
        
        // Execute first withdrawal
        vm.prank(sponsor);
        paymaster.executeWithdrawal(firstWithdrawalId);
        
        // Execute second withdrawal
        vm.prank(sponsor);
        paymaster.executeWithdrawal(secondWithdrawalId);
        
        // Check both are executed
        (, , bool firstExecuted) = paymaster.getPendingWithdrawal(sponsor, firstWithdrawalId);
        (, , bool secondExecuted) = paymaster.getPendingWithdrawal(sponsor, secondWithdrawalId);
        
        assertTrue(firstExecuted, "First withdrawal should be executed");
        assertTrue(secondExecuted, "Second withdrawal should be executed");
    }

    // TODO: Add tests for validatePaymasterUserOp and postOp with sponsor mode
    // These will require mocking UserOperation data, signatures, and EntryPoint interactions
} 