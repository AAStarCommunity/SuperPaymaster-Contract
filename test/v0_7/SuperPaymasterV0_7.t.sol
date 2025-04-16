// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { IStakeManager } from "singleton-paymaster/lib/account-abstraction-v7/contracts/interfaces/IStakeManager.sol";
import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { IPaymaster } from "@account-abstraction-v7/interfaces/IPaymaster.sol";

import { SuperPaymasterV0_7 } from "../../src/v0_7/SuperPaymasterV0_7.sol";
import { ISuperPaymaster } from "../../src/interfaces/ISuperPaymaster.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { MockEntryPoint } from "../mocks/MockEntryPoint.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";

// 添加ContextData结构体定义
struct ContextData {
    address sponsor;
    address token;
    uint256 maxEthCost;
    uint256 maxErc20Cost;
    bytes32 userOpHash;
    uint256 opIndex;
}

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
    
    // Private keys for signing
    uint256 public sponsorSignerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Foundry's first default test private key

    // Test constants
    uint256 public constant EXCHANGE_RATE = 1000; // 1000 tokens = 1 ETH
    uint256 public constant SPONSOR_DEPOSIT = 10 ether;
    uint256 public constant WARNING_THRESHOLD = 1 ether;
    uint256 public constant TEST_WITHDRAWAL_DELAY = 10 minutes; // Shorter delay for testing
    
    // Event for tracking withdrawals
    event WithdrawalExecuted(address indexed sponsor, uint256 indexed withdrawalId, uint256 amount);

    function setUp() public {
        // Setup addresses
        owner = makeAddr("owner");
        manager = makeAddr("manager");
        sponsor = makeAddr("sponsor");
        // 为sponsorSigner设置一个固定的私钥，以便生成一致的签名
        sponsorSigner = vm.addr(sponsorSignerPk);
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

        // Setup initial balances
        deal(sponsor, 100 ether);
        token.mint(user, 10000 * 10**18);
        
        // REMOVED: No longer registering the sponsor in setUp
        // vm.prank(owner);
        // paymaster.registerSponsor(sponsor);
        //
        // vm.startPrank(sponsor);
        // paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        // paymaster.setSponsorConfig(
        //     address(token),
        //     EXCHANGE_RATE,
        //     WARNING_THRESHOLD,
        //     sponsorSigner
        // );
        // paymaster.enableSponsor(true);
        // vm.stopPrank();
    }

    function testRegisterSponsor() public {
        address newSponsor = makeAddr("newSponsor");
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        assertTrue(paymaster.isSponsor(newSponsor), "Sponsor registration failed");
        
        ISuperPaymaster.SponsorConfig memory config = paymaster.getSponsorConfig(newSponsor);
        assertEq(config.owner, newSponsor, "Sponsor owner not set correctly");
        assertEq(config.isEnabled, false, "Sponsor should be disabled by default");
    }

    function testSponsorConfiguration() public {
        address newSponsor = makeAddr("configTestSponsor");
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // Configure sponsor
        vm.prank(newSponsor);
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            WARNING_THRESHOLD,
            sponsorSigner
        );
        
        // Verify configuration
        ISuperPaymaster.SponsorConfig memory config = paymaster.getSponsorConfig(newSponsor);
        assertEq(config.token, address(token), "Token not set correctly");
        assertEq(config.exchangeRate, EXCHANGE_RATE, "Exchange rate not set correctly");
        assertEq(config.warningThreshold, WARNING_THRESHOLD, "Warning threshold not set correctly");
        assertEq(config.signer, sponsorSigner, "Signer not set correctly");
        
        // Enable sponsor
        vm.prank(newSponsor);
        paymaster.enableSponsor(true);
        
        config = paymaster.getSponsorConfig(newSponsor);
        assertTrue(config.isEnabled, "Sponsor should be enabled");
    }

    function testDepositStake() public {
        address newSponsor = makeAddr("depositTestSponsor");
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // Check stake amount
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT, "Deposit amount incorrect");
    }
    
    function testWithdrawalRequest() public {
        address newSponsor = makeAddr("withdrawRequestTestSponsor");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // 请求提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(1 ether);
        
        // Check stake amount is decreased immediately
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT - 1 ether, "Stake amount not decreased after withdrawal request");
    }
    
    function testWithdrawalLock() public {
        address newSponsor = makeAddr("withdrawLockTestSponsor");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // 请求提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(1 ether);
        
        // Get withdrawal ID (should be 0 as it's the first withdrawal)
        uint256 withdrawalId = 0;
        
        // Check withdrawal request details
        (uint256 amount, uint256 unlockTime, bool executed) = paymaster.getPendingWithdrawal(newSponsor, withdrawalId);
        
        assertEq(amount, 1 ether, "Withdrawal amount incorrect");
        assertEq(unlockTime, block.timestamp + TEST_WITHDRAWAL_DELAY, "Unlock time incorrect");
        assertFalse(executed, "Withdrawal should not be executed yet");
        
        // Try to execute withdrawal before time lock expires (should fail)
        vm.prank(newSponsor);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterV0_7.WithdrawalStillLocked.selector, unlockTime));
        paymaster.executeWithdrawal(withdrawalId);
    }
    
    function testSponsorBalanceUpdateOnWithdrawal() public {
        address newSponsor = makeAddr("balanceUpdateTestSponsor");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // 初始余额检查
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT, "Initial stake incorrect");
        
        // 请求提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(1 ether);
        
        // 检查余额更新
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT - 1 ether, "Stake not updated after withdrawal request");
    }
    
    function testCancelWithdrawal() public {
        address newSponsor = makeAddr("cancelTestSponsor");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // 请求提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(2 ether);
        
        // Get withdrawal ID (should be 0 as it's the first withdrawal)
        uint256 withdrawalId = 0;
        
        // 在新的交易中取消提款
        vm.prank(newSponsor);
        paymaster.cancelWithdrawal(withdrawalId);
        
        // Check stake amount is restored
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT, "Stake amount not restored after cancellation");
    }
    
    function testFirstWithdrawal() public {
        address newSponsor = makeAddr("firstWithdrawalTestSponsor");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // 请求第一次提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(1 ether);
        
        // Check stake amount is decreased
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT - 1 ether, "Stake amount incorrect after first withdrawal");
        
        // Get withdrawal ID
        uint256 withdrawalId = 0;
        
        // Verify withdrawal details
        (uint256 amount, , bool executed) = paymaster.getPendingWithdrawal(newSponsor, withdrawalId);
        
        assertEq(amount, 1 ether, "First withdrawal amount incorrect");
        assertFalse(executed, "First withdrawal should not be executed yet");
    }
    
    function testSecondWithdrawal() public {
        address newSponsor = makeAddr("secondWithdrawalTestSponsor");
        
        // Register sponsor
        vm.prank(owner);
        paymaster.registerSponsor(newSponsor);
        
        // 给新sponsor充值ETH
        deal(newSponsor, SPONSOR_DEPOSIT + 1 ether);
        
        // Deposit stake
        vm.prank(newSponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        
        // 请求第一次提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(1 ether);
        
        // 请求第二次提款
        vm.prank(newSponsor);
        paymaster.withdrawStake(2 ether);
        
        // Check stake amount is decreased for both
        assertEq(paymaster.getSponsorStake(newSponsor), SPONSOR_DEPOSIT - 3 ether, "Stake amount incorrect after multiple withdrawals");
        
        // Get second withdrawal ID
        uint256 secondWithdrawalId = 1;
        
        // Verify second withdrawal details
        (uint256 amount2, , bool executed2) = paymaster.getPendingWithdrawal(newSponsor, secondWithdrawalId);
        
        assertEq(amount2, 2 ether, "Second withdrawal amount incorrect");
        assertFalse(executed2, "Second withdrawal should not be executed yet");
    }

    // Helper functions
    function setupSponsor() internal returns (address, address) {
        address _sponsorSigner = vm.addr(sponsorSignerPk);
        address _sponsor = address(0x1234567890123456789012345678901234567890);
        
        // 注册sponsor
        vm.prank(owner);
        paymaster.registerSponsor(_sponsor);
        
        // 为sponsor存入资金并配置
        vm.deal(_sponsor, SPONSOR_DEPOSIT);
        
        // 为sponsor铸造足够的ERC20代币
        token.mint(_sponsor, 1000 ether);
        
        vm.startPrank(_sponsor);
        paymaster.depositStake{value: SPONSOR_DEPOSIT}();
        paymaster.setSponsorConfig(
            address(token),
            EXCHANGE_RATE,
            WARNING_THRESHOLD,
            _sponsorSigner
        );
        paymaster.enableSponsor(true);
        vm.stopPrank();
        
        return (_sponsor, _sponsorSigner);
    }

    function createMockUserOp() internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(0x111),
            nonce: 1,
            initCode: "",
            callData: abi.encodeWithSignature("execute()"),
            accountGasLimits: bytes32(abi.encodePacked(uint128(100000), uint128(0))),
            preVerificationGas: uint256(100000),
            gasFees: bytes32(abi.encodePacked(uint128(1), uint128(1), uint64(0), uint48(block.timestamp + 100))),
            paymasterAndData: "",
            signature: ""
        });
    }

    function prepareSponsorDataForAddress(
        PackedUserOperation memory userOp,
        address targetSponsor,
        address /* targetSponsorSigner not used */
    ) internal returns (bytes memory paymasterAndData, bytes32 userOpHash) {
        // 计算userOpHash
        userOpHash = calculateUserOpHash(userOp);
        
        // 配置参数
        uint48 validUntil = uint48(block.timestamp + 100);
        uint48 validAfter = uint48(block.timestamp - 100);
        uint256 maxErc20Cost = 1 ether;
        
        // 签名消息和签名
        bytes memory signature = createSponsorSignature(
            userOpHash,
            targetSponsor,
            address(token),
            maxErc20Cost,
            validUntil,
            validAfter
        );
        
        // 构建完整的paymasterAndData
        paymasterAndData = buildPaymasterAndData(
            validUntil,
            validAfter,
            targetSponsor,
            maxErc20Cost,
            signature
        );
        
        return (paymasterAndData, userOpHash);
    }
    
    function calculateUserOpHash(PackedUserOperation memory userOp) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            userOp.sender,
            userOp.nonce,
            keccak256(userOp.callData)
        ));
    }
    
    function createSponsorSignature(
        bytes32 userOpHash,
        address targetSponsor,
        address tokenAddress,
        uint256 maxErc20Cost,
        uint48 validUntil,
        uint48 validAfter
    ) internal returns (bytes memory) {
        // 签名消息
        bytes32 msgHash = keccak256(abi.encodePacked(
            userOpHash,
            address(paymaster),
            targetSponsor,
            tokenAddress,
            maxErc20Cost,
            validUntil,
            validAfter,
            block.chainid
        ));
        
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(msgHash);
        
        // 使用提供的签名者进行签名
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sponsorSignerPk, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }
    
    function buildPaymasterAndData(
        uint48 validUntil,
        uint48 validAfter,
        address targetSponsor,
        uint256 maxErc20Cost,
        bytes memory signature
    ) internal view returns (bytes memory) {
        // First construct the paymasterConfig part
        bytes memory paymasterConfig = _createPaymasterConfig(
            validUntil,
            validAfter,
            targetSponsor,
            maxErc20Cost,
            signature
        );
        
        // Then add the paymaster header data
        return _addPaymasterHeader(paymasterConfig);
    }
    
    function _createPaymasterConfig(
        uint48 validUntil,
        uint48 validAfter,
        address targetSponsor,
        uint256 maxErc20Cost,
        bytes memory signature
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            bytes6(abi.encodePacked(validUntil)),
            bytes6(abi.encodePacked(validAfter)),
            bytes20(abi.encodePacked(targetSponsor)),
            bytes20(abi.encodePacked(address(token))),
            bytes32(abi.encodePacked(maxErc20Cost)),
            signature
        );
    }
    
    function _addPaymasterHeader(bytes memory paymasterConfig) internal view returns (bytes memory) {
        uint8 mode = 1; // SPONSOR_MODE = 1
        bool allowAllBundlers = true;
        
        return abi.encodePacked(
            address(paymaster),
            bytes16(abi.encodePacked(uint128(1000000))), // verification gas
            bytes16(abi.encodePacked(uint128(1000000))), // post op gas 
            bytes1(abi.encodePacked(uint8(mode << 1 | (allowAllBundlers ? 1 : 0)))),
            paymasterConfig
        );
    }

    // 添加回内部辅助函数
    function _prepareMockSponsorData(address _sponsor, bytes32 userOpHash) internal returns (bytes memory) {
        // Prepare the configuration parameters
        uint48 validUntil = uint48(block.timestamp + 100);
        uint48 validAfter = uint48(block.timestamp - 100);
        uint256 maxErc20Cost = 1 ether;
        
        // Create signature
        bytes memory signature = createSponsorSignature(
            userOpHash,
            _sponsor,
            address(token),
            maxErc20Cost,
            validUntil,
            validAfter
        );
        
        // Build and return the full paymasterAndData
        return buildPaymasterAndData(
            validUntil,
            validAfter,
            _sponsor,
            maxErc20Cost,
            signature
        );
    }
} 