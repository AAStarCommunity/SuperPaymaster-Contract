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
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";
import { PaymasterHelpers } from "../../src/utils/PaymasterHelpers.sol";

/**
 * @title SuperPaymasterV0_7 Edge Case Test
 * @notice Testing edge cases and boundary conditions for the SuperPaymaster contract
 */
contract EdgeCaseTest is Test {
    // Contract instances
    SuperPaymasterV0_7 public paymaster;
    MockEntryPoint public entryPoint;
    MockERC20 public token;

    // Test addresses
    address public owner;
    address public manager;
    address public sponsor;
    address public sponsorSigner;
    address public user;
    address public bundler;
    
    // Test constants
    uint256 public constant EXCHANGE_RATE = 100; // 100 token = 1 ETH (small to avoid overflow)
    uint256 public constant SPONSOR_DEPOSIT = 1 ether;
    uint256 public constant WARNING_THRESHOLD = 0.1 ether;

    function setUp() public {
        // Setup addresses
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        sponsor = makeAddr("sponsor");
        sponsorSigner = makeAddr("sponsorSigner");
        user = makeAddr("user");
        bundler = makeAddr("bundler");

        // Deploy contracts
        vm.startPrank(owner);
        entryPoint = new MockEntryPoint();
        token = new MockERC20("TestToken", "TT", 18);
        
        address[] memory signers = new address[](1);
        signers[0] = manager;
        
        paymaster = new SuperPaymasterV0_7(
            address(entryPoint),
            owner,
            manager,
            signers
        );
        
        // Allow bundler
        paymaster.addBundler(bundler);
        vm.stopPrank();

        // Setup sponsor
        vm.startPrank(owner);
        paymaster.registerSponsor(sponsor);
        vm.stopPrank();
        
        // Give sponsor enough ETH
        deal(sponsor, SPONSOR_DEPOSIT + 1 ether);
        
        vm.startPrank(sponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            WARNING_THRESHOLD,
            sponsorSigner
        );
        paymaster.enableSponsor(true);
        vm.stopPrank();
        
        // Setup user
        deal(user, 1 ether);
        token.mint(user, 1000 ether);
        
        vm.prank(user);
        token.approve(address(paymaster), 1000 ether);
    }

    /**
     * @notice Test withdrawal with zero amount
     */
    function testWithdrawalZeroAmount() public {
        vm.startPrank(sponsor);
        vm.expectRevert("SuperPaymaster: zero amount"); // Expected error message
        paymaster.initiateWithdrawal(0);
        vm.stopPrank();
    }

    /**
     * @notice Test withdrawal exceeding available balance
     */
    function testWithdrawalExceedingBalance() public {
        uint256 balance = paymaster.getSponsorStake(sponsor);
        
        vm.startPrank(sponsor);
        vm.expectRevert("SuperPaymaster: insufficient unlocked stake");
        paymaster.initiateWithdrawal(balance + 1 ether);
        vm.stopPrank();
    }

    /**
     * @notice Test zero address sponsor registration
     */
    function testRegisterZeroAddressSponsor() public {
        vm.startPrank(owner);
        vm.expectRevert("SuperPaymaster: zero address");
        paymaster.registerSponsor(address(0));
        vm.stopPrank();
    }

    /**
     * @notice Test registering sponsor by non-admin
     */
    function testRegisterSponsorByNonAdmin() public {
        address randomUser = makeAddr("randomUser");
        vm.startPrank(randomUser);
        vm.expectRevert("SuperPaymaster: not admin or manager");
        paymaster.registerSponsor(randomUser);
        vm.stopPrank();
    }

    /**
     * @notice Test zero deposit
     */
    function testZeroDeposit() public {
        address newSponsor = makeAddr("newSponsor");
        
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        vm.startPrank(newSponsor);
        vm.expectRevert("SuperPaymaster: zero deposit");
        paymaster.depositStake{value: 0}();
        vm.stopPrank();
    }

    /**
     * @notice Test deposit by non-sponsor
     */
    function testDepositByNonSponsor() public {
        address nonSponsor = makeAddr("nonSponsor");
        deal(nonSponsor, 1 ether);
        
        vm.startPrank(nonSponsor);
        vm.expectRevert("SuperPaymaster: sender not sponsor");
        paymaster.depositStake{value: 1 ether}();
        vm.stopPrank();
    }

    /**
     * @notice Test setting invalid exchange rate
     */
    function testInvalidExchangeRate() public {
        vm.startPrank(sponsor);
        vm.expectRevert("SuperPaymaster: invalid exchange rate");
        paymaster.setSponsorConfig(
            address(token),
            0, // Zero exchange rate
            WARNING_THRESHOLD,
            sponsorSigner
        );
        vm.stopPrank();
    }

    /**
     * @notice Test setting invalid signer address
     */
    function testInvalidSigner() public {
        vm.startPrank(sponsor);
        vm.expectRevert("SuperPaymaster: invalid signer address");
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            WARNING_THRESHOLD,
            address(0) // Zero address signer
        );
        vm.stopPrank();
    }

    /**
     * @notice Test validatePaymasterUserOp with insufficient sponsor stake
     */
    function testValidateWithInsufficientStake() public {
        // Setup minimal sponsor
        address poorSponsor = makeAddr("poorSponsor");
        address poorSponsorSigner = makeAddr("poorSponsorSigner");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(poorSponsor);
        
        // Deposit minimal stake
        deal(poorSponsor, 0.01 ether);
        vm.startPrank(poorSponsor);
        paymaster.depositStake{value: 0.01 ether}();
        
        // Configure sponsor
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            0.001 ether, // Very low warning threshold
            poorSponsorSigner
        );
        
        paymaster.enableSponsor(true);
        vm.stopPrank();
        
        // Create UserOp
        PackedUserOperation memory userOp = _createMockUserOp(user);
        
        // Prepare signature
        bytes32 userOpHash = keccak256(abi.encodePacked("testHash"));
        bytes memory signature = _createSponsorSignature(userOpHash, poorSponsor, poorSponsorSigner, address(token), 10 ether);
        
        // Create paymasterAndData
        bytes memory paymasterData = abi.encodePacked(
            bytes1(uint8(1 << 1 | 0)), // mode flag (sponsor mode)
            bytes6(uint48(block.timestamp + 100)), // validUntil
            bytes6(uint48(block.timestamp - 10)),  // validAfter
            bytes20(poorSponsor), // sponsor address
            bytes20(address(token)), // token address
            bytes32(uint256(10 ether)), // maxTokenCost
            signature
        );
        
        userOp.paymasterAndData = paymasterData;
        
        // Try to validate with high maxCost
        vm.startPrank(address(entryPoint));
        vm.expectRevert("SuperPaymaster: insufficient sponsor stake");
        paymaster.validatePaymasterUserOp(userOp, userOpHash, 0.1 ether); // High cost compared to deposit
        vm.stopPrank();
    }

    /**
     * @notice Test postOp with actual cost exceeding max cost
     */
    function testPostOpExceedingMaxCost() public {
        // Create a simple context
        bytes memory context = abi.encode(
            sponsor,
            address(token),
            uint256(0.01 ether), // maxEthCost
            uint256(1 ether),    // maxErc20Cost
            keccak256("testHash")
        );
        
        // Try to call postOp with cost exceeding maxEthCost
        vm.startPrank(address(entryPoint));
        vm.expectRevert("SuperPaymaster: actual cost exceeds max");
        paymaster.postOp(PostOpMode.opSucceeded, context, 0.02 ether, 1); // Double the maxCost
        vm.stopPrank();
    }

    /**
     * @notice Test accessing getERC20Balance with non-existent token
     */
    function testGetERC20BalanceNonExistentToken() public {
        // Non-existent token address
        address nonExistentToken = makeAddr("nonExistentToken");
        
        // This should not revert but return 0
        uint256 balance = paymaster.getERC20Balance(nonExistentToken, user);
        assertEq(balance, 0, "Balance of non-existent token should be 0");
    }

    /**
     * @notice Test calling validatePaymasterUserOp with expired validation (validUntil in the past)
     */
    function testExpiredValidation() public {
        // Create UserOp
        PackedUserOperation memory userOp = _createMockUserOp(user);
        
        // Create expired validation data
        bytes32 userOpHash = keccak256(abi.encodePacked("testHash"));
        bytes memory signature = _createSponsorSignature(userOpHash, sponsor, sponsorSigner, address(token), 10 ether);
        
        bytes memory paymasterData = abi.encodePacked(
            bytes1(uint8(1 << 1 | 0)), // mode flag (sponsor mode)
            bytes6(uint48(block.timestamp - 200)), // validUntil in the past
            bytes6(uint48(block.timestamp - 300)), // validAfter 
            bytes20(sponsor), // sponsor address
            bytes20(address(token)), // token address
            bytes32(uint256(10 ether)), // maxTokenCost
            signature
        );
        
        userOp.paymasterAndData = paymasterData;
        
        // Validation should fail due to expired timestamp
        vm.startPrank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, userOpHash, 0.01 ether);
        vm.stopPrank();
        
        // Extract validUntil from validationData (bits 160-208)
        uint256 validUntil = (validationData >> 160) & ((1 << 48) - 1);
        
        // Assert that validation failed due to timestamp
        assertTrue(validUntil < block.timestamp, "Validation should fail due to expired timestamp");
        assertTrue(validationData > 0, "Validation data should indicate failure");
    }

    /**
     * @notice Test validation with future validAfter
     */
    function testFutureValidAfter() public {
        // Create UserOp
        PackedUserOperation memory userOp = _createMockUserOp(user);
        
        // Create validation data with future validAfter
        bytes32 userOpHash = keccak256(abi.encodePacked("testHash"));
        bytes memory signature = _createSponsorSignature(userOpHash, sponsor, sponsorSigner, address(token), 10 ether);
        
        bytes memory paymasterData = abi.encodePacked(
            bytes1(uint8(1 << 1 | 0)), // mode flag (sponsor mode)
            bytes6(uint48(block.timestamp + 300)), // validUntil
            bytes6(uint48(block.timestamp + 100)), // validAfter in the future
            bytes20(sponsor), // sponsor address
            bytes20(address(token)), // token address
            bytes32(uint256(10 ether)), // maxTokenCost
            signature
        );
        
        userOp.paymasterAndData = paymasterData;
        
        // Validation should fail due to future validAfter
        vm.startPrank(address(entryPoint));
        (bytes memory context, uint256 validationData) = paymaster.validatePaymasterUserOp(userOp, userOpHash, 0.01 ether);
        vm.stopPrank();
        
        // Extract validAfter from validationData (bits 208-256)
        uint256 validAfter = (validationData >> (160 + 48));
        
        // Assert that validation failed due to future timestamp
        assertTrue(validAfter > block.timestamp, "Validation should fail due to future validAfter");
        assertTrue(validationData > 0, "Validation data should indicate failure");
    }

    /**
     * @notice Test calling postOp from non-EntryPoint address
     */
    function testPostOpFromNonEntryPoint() public {
        // Create a simple context
        bytes memory context = abi.encode(
            sponsor,
            address(token),
            uint256(0.01 ether),
            uint256(1 ether),
            keccak256("testHash")
        );
        
        // Call postOp from non-EntryPoint address
        vm.startPrank(user); // Using regular user instead of EntryPoint
        vm.expectRevert("SuperPaymaster: not EntryPoint");
        paymaster.postOp(PostOpMode.opSucceeded, context, 0.005 ether, 1);
        vm.stopPrank();
    }

    /**
     * @notice Test sponsor withdrawal during locked state
     */
    function testWithdrawalDuringLock() public {
        // Create UserOp and context
        PackedUserOperation memory userOp = _createMockUserOp(user);
        bytes32 userOpHash = keccak256(abi.encodePacked("testHash"));
        
        // Prepare signature and data
        bytes memory signature = _createSponsorSignature(userOpHash, sponsor, sponsorSigner, address(token), 10 ether);
        bytes memory paymasterData = abi.encodePacked(
            bytes1(uint8(1 << 1 | 0)),
            bytes6(uint48(block.timestamp + 100)),
            bytes6(uint48(block.timestamp - 10)),
            bytes20(sponsor),
            bytes20(address(token)),
            bytes32(uint256(10 ether)),
            signature
        );
        
        userOp.paymasterAndData = paymasterData;
        
        // Lock funds by validating
        vm.prank(address(entryPoint));
        paymaster.validatePaymasterUserOp(userOp, userOpHash, 0.1 ether);
        
        // Try to withdraw while locked
        vm.startPrank(sponsor);
        vm.expectRevert("SuperPaymaster: insufficient unlocked stake");
        paymaster.initiateWithdrawal(0.5 ether);
        vm.stopPrank();
        
        // Complete the operation to unlock
        bytes memory context = abi.encode(
            sponsor,
            address(token),
            uint256(0.1 ether),
            uint256(10 ether),
            userOpHash
        );
        
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, context, 0.05 ether, 1);
        
        // Now withdrawal should succeed
        vm.startPrank(sponsor);
        paymaster.initiateWithdrawal(0.1 ether); // Should succeed
        vm.stopPrank();
    }

    /**
     * @notice Test executing withdrawal that doesn't exist
     */
    function testNonExistentWithdrawal() public {
        vm.startPrank(sponsor);
        vm.expectRevert("SuperPaymaster: invalid withdrawal index");
        paymaster.executeWithdrawal(999); // Non-existent withdrawal ID
        vm.stopPrank();
    }

    // ==================== Helper Functions ====================

    function _createMockUserOp(address _user) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: _user,
            nonce: uint256(keccak256(abi.encodePacked(_user, block.timestamp))) % 100,
            initCode: bytes(""),
            callData: abi.encodeCall(token.transfer, (address(0x123), 10)),
            accountGasLimits: bytes32(abi.encodePacked(uint128(100000), uint128(100000))),
            preVerificationGas: 10000,
            gasFees: bytes32(abi.encodePacked(
                uint128(1e8),
                uint128(1e7),
                uint64(0),
                uint48(block.timestamp + 100)
            )),
            paymasterAndData: hex"",
            signature: hex""
        });
    }

    function _createSponsorSignature(
        bytes32 userOpHash,
        address _sponsor,
        address _sponsorSigner,
        address _token,
        uint256 _maxErc20Cost
    ) internal returns (bytes memory) {
        // Prepare timestamps
        uint48 validUntil = uint48(block.timestamp + 100);
        uint48 validAfter = uint48(block.timestamp - 10);
        
        // Create hash for signing
        bytes32 hash = keccak256(
            abi.encodePacked(
                userOpHash,
                address(paymaster),
                _sponsor,
                _token,
                _maxErc20Cost,
                validUntil,
                validAfter,
                block.chainid
            )
        );
        
        bytes32 message = MessageHashUtils.toEthSignedMessageHash(hash);
        
        // Generate signature using a fixed private key
        uint256 pk = 0x1234;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, message);
        
        return abi.encodePacked(r, s, v);
    }
} 