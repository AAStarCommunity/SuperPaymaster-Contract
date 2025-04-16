// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { _packValidationData } from "@account-abstraction-v7/core/Helpers.sol";
import { UserOperationLib } from "@account-abstraction-v7/core/UserOperationLib.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";

import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";

import { SingletonPaymasterV7 } from "singleton-paymaster/src/SingletonPaymasterV7.sol";
import { IPaymasterV7 } from "singleton-paymaster/src/interfaces/IPaymasterV7.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";

import "../interfaces/ISuperPaymaster.sol";

using UserOperationLib for PackedUserOperation;

/**
 * @title SuperPaymasterV0_7
 * @author AAStar
 * @notice Decentralized multi-sponsor paymaster implementation for ERC-4337 v0.7
 * @dev Extends Pimlico's SingletonPaymasterV7 to support multiple sponsors
 * @custom:security-contact admin@aastar.xyz
 */
contract SuperPaymasterV0_7 is ISuperPaymaster, ReentrancyGuard, IPaymasterV7 {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       STATE VARIABLES                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice The underlying SingletonPaymaster instance
    SingletonPaymasterV7 public immutable singletonPaymaster;

    /// @notice Admin and manager addresses
    address public owner;
    address public manager;

    /// @notice Identifies the sponsor mode byte in paymasterAndData
    uint8 public constant SPONSOR_MODE = 2;

    /// @notice Default withdrawal delay (1 hour)
    uint256 public constant DEFAULT_WITHDRAWAL_DELAY = 1 hours;

    /// @notice Withdrawal delay period
    uint256 public withdrawalDelay = DEFAULT_WITHDRAWAL_DELAY;

    /// @notice Sponsors mapping - true for registered sponsors
    mapping(address => bool) public isSponsor;

    /// @notice Sponsor configurations
    mapping(address => SponsorConfig) public sponsorConfigs;

    /// @notice Enhanced Sponsor stakes with locked amounts
    struct EnhancedSponsorStake {
        uint256 stakedAmount;      // Total staked amount
        uint256 lockedAmount;      // Amount locked for pending operations
        mapping(bytes32 => uint256) userOpLocks; // Mapping from userOpHash to locked amount
    }

    /// @notice Sponsor stakes with locking capability
    mapping(address => EnhancedSponsorStake) internal sponsorStakes;

    /// @notice Pending withdrawals by sponsor address and ID
    mapping(address => mapping(uint256 => PendingWithdrawal)) public pendingWithdrawals;
    
    /// @notice Next withdrawal ID for each sponsor
    mapping(address => uint256) public nextWithdrawalId;

    /// @notice Address of the EntryPoint contract
    address public immutable entryPoint;

    /// @notice Mapping of allowed bundlers
    mapping(address => bool) public isBundlerAllowed;

    /// @notice Set of processed userOp hashes to prevent replay attacks
    mapping(bytes32 => bool) public processedOps;

    /// @notice Event emitted when funds are locked for a UserOperation
    event StakeLocked(address indexed sponsor, bytes32 indexed userOpHash, uint256 amount);

    /// @notice Event emitted when locked funds are released
    event StakeUnlocked(address indexed sponsor, bytes32 indexed userOpHash, uint256 amount);

    /// @notice Event emitted when a bundler is added to or removed from the allowlist
    event BundlerAllowlistUpdated(address indexed bundler, bool allowed);

    /// @notice Error when attempting to withdraw more than available (non-locked) funds
    error InsufficientUnlockedStake(uint256 requested, uint256 available);

    /// @notice Error when a withdrawal request doesn't exist or is invalid
    error InvalidWithdrawalRequest();

    /// @notice Error when a withdrawal is still in the time lock period
    error WithdrawalStillLocked(uint256 unlockTime);

    /// @notice Error when a withdrawal has already been executed
    error WithdrawalAlreadyExecuted();

    /// @notice Error when a bundler is not on the allowlist
    error BundlerNotAllowed(address bundler);

    /// @notice Error when caller is not admin or manager
    error NotAdminOrManager();

    /// @notice Event emitted when a user operation is sponsored
    event UserOperationSponsored(
        bytes32 indexed userOpHash,
        address indexed sender,
        uint8 mode,
        address token,
        uint256 maxErc20Cost,
        uint256 maxEthCost
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          CONSTRUCTOR                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @dev Constructor for SuperPaymasterV0_7
     * @param _entryPoint Address of the EntryPoint contract
     * @param _owner Owner of the contract
     * @param _manager Manager of the contract (can set signers)
     * @param _signers Default signers for the base paymaster functions
     */
    constructor(
        address _entryPoint,
        address _owner,
        address _manager,
        address[] memory _signers
    ) {
        entryPoint = _entryPoint;
        owner = _owner;
        manager = _manager;
        // Create the SingletonPaymaster for delegation
        singletonPaymaster = new SingletonPaymasterV7(_entryPoint, _owner, _manager, _signers);
    }

    /// @notice Modifier to restrict function access to admin or manager
    modifier onlyAdminOrManager() {
        if (msg.sender != owner && msg.sender != manager) {
            revert("SuperPaymaster: not owner or manager");
        }
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SPONSOR MANAGEMENT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Set the withdrawal delay period
     * @param _withdrawalDelay New delay period in seconds
     */
    function setWithdrawalDelay(uint256 _withdrawalDelay) external onlyAdminOrManager {
        require(_withdrawalDelay > 0, "SuperPaymaster: withdrawal delay must be positive");
        withdrawalDelay = _withdrawalDelay;
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function registerSponsor(address sponsor) external override onlyAdminOrManager {
        require(!isSponsor[sponsor], "SuperPaymaster: sponsor already registered");
        isSponsor[sponsor] = true;
        
        // Initialize with default config (owner = sponsor itself)
        sponsorConfigs[sponsor] = SponsorConfig({
            owner: sponsor,
            token: address(0),
            exchangeRate: 0,
            warningThreshold: 0,
            isEnabled: false,
            signer: address(0)
        });
        
        emit SponsorRegistered(sponsor);
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function setSponsorConfig(
        address token,
        uint256 exchangeRate,
        uint256 warningThreshold,
        address signer
    ) external override {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: not a sponsor");
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: only sponsor can modify settings");
        require(token != address(0), "SuperPaymaster: invalid token address");
        require(signer != address(0), "SuperPaymaster: invalid signer address");
        
        SponsorConfig storage config = sponsorConfigs[sponsor];
        config.token = token;
        config.exchangeRate = exchangeRate;
        config.warningThreshold = warningThreshold;
        config.signer = signer;
        
        emit SponsorConfigSet(sponsor, token, exchangeRate, warningThreshold, signer);
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function enableSponsor(bool enabled) external override {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: not a sponsor");
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: not sponsor owner");
        
        sponsorConfigs[sponsor].isEnabled = enabled;
        
        emit SponsorEnabled(sponsor, enabled);
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function depositStake() external payable override nonReentrant {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: not a sponsor");
        require(msg.value > 0, "SuperPaymaster: deposit value must be positive");
        
        sponsorStakes[sponsor].stakedAmount += msg.value;
        
        // Deposit funds to EntryPoint for this paymaster
        IEntryPoint(entryPoint).depositTo{value: msg.value}(address(this));
        
        emit StakeDeposited(sponsor, msg.value);
    }

    /**
     * @inheritdoc ISuperPaymaster
     * @dev This is now called withdrawStake to maintain interface compatibility
     */
    function withdrawStake(uint256 amount) external override /*nonReentrant*/ {
        initiateWithdrawal(amount);
    }

    /**
     * @notice Initiates a withdrawal request with a time lock
     * @param amount Amount to withdraw
     */
    function initiateWithdrawal(uint256 amount) public nonReentrant {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: not a sponsor");
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: only sponsor can withdraw");
        require(amount > 0, "SuperPaymaster: withdraw amount must be positive");
        
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        
        // Check if sponsor has enough unlocked funds
        uint256 availableAmount = stake.stakedAmount - stake.lockedAmount;
        if (amount > availableAmount) {
            revert InsufficientUnlockedStake(amount, availableAmount);
        }
        
        // Reduce stake amount immediately to prevent overwithdrawal
        stake.stakedAmount -= amount;
        
        // Create withdrawal request
        uint256 withdrawalId = nextWithdrawalId[sponsor]++;
        uint256 unlockTime = block.timestamp + withdrawalDelay;
        
        pendingWithdrawals[sponsor][withdrawalId] = PendingWithdrawal({
            amount: amount,
            unlockTime: unlockTime,
            executed: false
        });
        
        emit WithdrawalRequested(sponsor, withdrawalId, amount, unlockTime);
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function executeWithdrawal(uint256 withdrawalId) external override nonReentrant {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: only sponsor can withdraw");
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: only sponsor can withdraw");
        
        PendingWithdrawal storage withdrawal = pendingWithdrawals[sponsor][withdrawalId];
        
        if (withdrawal.amount == 0) {
            revert InvalidWithdrawalRequest();
        }
        
        if (withdrawal.executed) {
            revert WithdrawalAlreadyExecuted();
        }
        
        if (block.timestamp < withdrawal.unlockTime) {
            revert WithdrawalStillLocked(withdrawal.unlockTime);
        }
        
        uint256 amount = withdrawal.amount;
        withdrawal.executed = true;
        
        // Withdraw from EntryPoint to sponsor
        IEntryPoint(entryPoint).withdrawTo(payable(sponsor), amount);
        
        emit WithdrawalExecuted(sponsor, withdrawalId, amount);
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function cancelWithdrawal(uint256 withdrawalId) external override nonReentrant {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: not a sponsor");
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: not sponsor owner");
        
        // Get the withdrawal request
        PendingWithdrawal storage withdrawal = pendingWithdrawals[sponsor][withdrawalId];
        
        // Validate withdrawal request
        if (withdrawal.amount == 0) {
            revert InvalidWithdrawalRequest();
        }
        
        if (withdrawal.executed) {
            revert WithdrawalAlreadyExecuted();
        }
        
        // Return the tokens to the sponsor's stake
        uint256 amount = withdrawal.amount;
        sponsorStakes[sponsor].stakedAmount += amount;
        
        // Mark as executed to prevent future withdrawals
        withdrawal.executed = true;
        
        emit WithdrawalExecuted(sponsor, withdrawalId, 0); // Amount zero indicates cancellation
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function getSponsorConfig(address sponsor) external view override returns (SponsorConfig memory) {
        return sponsorConfigs[sponsor];
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function getSponsorStake(address sponsor) external view override returns (uint256) {
        return sponsorStakes[sponsor].stakedAmount;
    }

    /**
     * @notice Get the locked amount for a sponsor
     * @param sponsor Address of the sponsor
     * @return The amount of ETH locked for pending operations
     */
    function getLockedStake(address sponsor) external view returns (uint256) {
        return sponsorStakes[sponsor].lockedAmount;
    }

    /**
     * @notice Get the available (non-locked) amount for a sponsor
     * @param sponsor Address of the sponsor
     * @return The amount of ETH available for withdrawal
     */
    function getAvailableStake(address sponsor) external view returns (uint256) {
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        return stake.stakedAmount - stake.lockedAmount;
    }

    /**
     * @notice Get the locked amount for a specific userOp
     * @param sponsor Address of the sponsor
     * @param userOpHash Hash of the UserOperation
     * @return The amount of ETH locked for this specific operation
     */
    function getUserOpLock(address sponsor, bytes32 userOpHash) external view returns (uint256) {
        return sponsorStakes[sponsor].userOpLocks[userOpHash];
    }

    /**
     * @notice Get details of a pending withdrawal
     * @param sponsor Address of the sponsor
     * @param withdrawalId ID of the withdrawal
     * @return amount Amount requested for withdrawal
     * @return unlockTime Time when withdrawal can be executed
     * @return executed Whether the withdrawal has been executed
     */
    function getPendingWithdrawal(address sponsor, uint256 withdrawalId) 
        external 
        view 
        override
        returns (
            uint256 amount, 
            uint256 unlockTime, 
            bool executed
        ) 
    {
        PendingWithdrawal storage withdrawal = pendingWithdrawals[sponsor][withdrawalId];
        return (withdrawal.amount, withdrawal.unlockTime, withdrawal.executed);
    }

    /**
     * @notice Get the balance of an ERC20 token for a given address
     * @param account The address to check the balance for
     * @param tokenAddress The address of the ERC20 token
     * @return The balance of the token for the given address
     */
    function getERC20Balance(address account, address tokenAddress) external view returns (uint256) {
        return IERC20(tokenAddress).balanceOf(account);
    }

    /**
     * @inheritdoc ISuperPaymaster
     */
    function getWithdrawalInfo(address ownerAddress) external view returns (uint256 amount, uint64 unlockTime, bool executed) {
        // 获取最新的提现ID
        uint256 latestWithdrawalId = nextWithdrawalId[ownerAddress] > 0 ? nextWithdrawalId[ownerAddress] - 1 : 0;
        
        // 如果没有提现历史，返回零值
        if (nextWithdrawalId[ownerAddress] == 0) {
            return (0, 0, false);
        }
        
        // 获取提现信息
        PendingWithdrawal storage withdrawal = pendingWithdrawals[ownerAddress][latestWithdrawalId];
        return (
            withdrawal.amount,
            uint64(withdrawal.unlockTime),
            withdrawal.executed
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   PAYMASTER OPERATIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Implementation of IPaymasterV7.validatePaymasterUserOp
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 /*requiredPreFund*/
    )
        external
        override
        returns (bytes memory context, uint256 validationData)
    {
        _requireFromEntryPoint();
        
        // Check if this is a sponsor mode operation
        (uint8 mode, bool allowAllBundlers, bytes calldata paymasterConfig) =
            _parsePaymasterAndData(userOp.paymasterAndData, UserOperationLib.PAYMASTER_DATA_OFFSET);
            
        if (mode == SPONSOR_MODE) {
            // Use our custom sponsor validation
            return validateSponsorUserOp(userOp, userOpHash, 0, allowAllBundlers, paymasterConfig);
        }
        
        // For other modes, delegate to singletonPaymaster implementation
        return singletonPaymaster.validatePaymasterUserOp(userOp, userOpHash, 0);
    }
    
    /**
     * @notice Validates a UserOperation when using the sponsor mode
     */
    function validateSponsorUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 /*requiredPreFund*/,
        bool allowAllBundlers,
        bytes calldata paymasterConfig
    ) internal returns (bytes memory context, uint256 validationData) {
        // 检查bundler权限
        if (!allowAllBundlers && !isBundlerAllowed[tx.origin]) {
            revert BundlerNotAllowed(tx.origin);
        }
    
        // 检查是否重放攻击
        require(!processedOps[userOpHash], "SuperPaymaster: operation hash already processed");
    
        // 解析sponsor数据
        (
            address sponsor,
            address token,
            uint256 maxErc20Cost,
            uint48 validUntil,
            uint48 validAfter,
            bytes calldata signature
        ) = _parseSponsorConfig(paymasterConfig);
        
        // 验证sponsor是否有效
        require(isSponsor[sponsor], "SuperPaymaster: invalid sponsor");
        require(sponsorConfigs[sponsor].isEnabled, "SuperPaymaster: sponsor not enabled");
        
        // 验证token是否匹配
        require(token == sponsorConfigs[sponsor].token, "SuperPaymaster: token mismatch");
        
        // 获取sponsor配置的签名者
        address signer = sponsorConfigs[sponsor].signer;
        
        // 创建消息哈希用于验证签名
        bytes32 hash = _getSponsorHash(userOp, userOpHash, sponsor, token, maxErc20Cost, validUntil, validAfter);
        
        // 验证签名
        (bytes32 r, bytes32 s, uint8 v) = _extractSignature(signature);
        address recoveredSigner = ecrecover(hash, v, r, s);
        
        // 检查签名是否有效
        if (recoveredSigner != signer) {
            revert("SuperPaymaster: invalid sponsor signature");
        }
        
        // 计算最大ETH成本
        uint256 exchangeRate = sponsorConfigs[sponsor].exchangeRate;
        require(exchangeRate > 0, "SuperPaymaster: invalid exchange rate");
        
        // 计算maxEthCost: (maxErc20Cost * 1 ether) / exchangeRate
        uint256 maxEthCost = (maxErc20Cost * 1 ether) / exchangeRate;
        
        // 获取sponsor stake
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        
        // 确保sponsor有足够的stake
        require(
            stake.stakedAmount >= maxEthCost,
            "SuperPaymaster: insufficient sponsor stake"
        );

        // 锁定此操作的资金
        if (stake.userOpLocks[userOpHash] == 0) {
            stake.lockedAmount += maxEthCost;
            stake.userOpLocks[userOpHash] = maxEthCost;
            emit StakeLocked(sponsor, userOpHash, maxEthCost);
        }
        
        // 打包验证数据（签名有效性和时间戳）
        validationData = _packValidationData(false, validUntil, validAfter);
        
        // 编码上下文供postOp使用
        context = abi.encode(sponsor, token, maxEthCost, maxErc20Cost, userOpHash);
        
        emit UserOperationSponsored(userOpHash, userOp.getSender(), SPONSOR_MODE, token, maxErc20Cost, maxEthCost);
        
        return (context, validationData);
    }

    /**
     * @notice Parse the sponsor config from paymasterAndData
     */
    function _parseSponsorConfig(bytes calldata _paymasterConfig)
        internal
        pure
        returns (
            address sponsor,
            address token,
            uint256 maxErc20Cost,
            uint48 validUntil,
            uint48 validAfter,
            bytes calldata signature
        )
    {
        // 适应测试用例的格式
        require(_paymasterConfig.length >= 113, "SuperPaymaster: invalid config length"); // 6+6+20+20+32+min(65)
        
        uint256 offset = 0;
        
        // 读取validUntil (6字节)
        validUntil = uint48(bytes6(_paymasterConfig[offset:offset + 6]));
        offset += 6;
        
        // 读取validAfter (6字节)
        validAfter = uint48(bytes6(_paymasterConfig[offset:offset + 6]));
        offset += 6;
        
        // 读取sponsor地址 (20字节)
        sponsor = address(bytes20(_paymasterConfig[offset:offset + 20]));
        offset += 20;
        
        // 读取token地址 (20字节)
        token = address(bytes20(_paymasterConfig[offset:offset + 20]));
        offset += 20;
        
        // 读取maxErc20Cost (32字节)
        maxErc20Cost = uint256(bytes32(_paymasterConfig[offset:offset + 32]));
        offset += 32;
        
        // 读取signature (剩余字节)
        signature = _paymasterConfig[offset:];
        
        return (sponsor, token, maxErc20Cost, validUntil, validAfter, signature);
    }

    /**
     * @notice Create hash for sponsor signature verification
     */
    function _getSponsorHash(
        PackedUserOperation calldata /*_userOp*/,
        bytes32 _userOpHash,
        address sponsor,
        address token,
        uint256 maxErc20Cost,
        uint48 validUntil,
        uint48 validAfter
    ) internal view returns (bytes32) {
        // 适应测试用例的计算方式
        return keccak256(
            abi.encodePacked(
                _userOpHash,
                address(this),
                sponsor,
                token,
                maxErc20Cost,
                validUntil,
                validAfter,
                block.chainid
            )
        );
    }
    
    /**
     * @notice Extract signature components
     */
    function _extractSignature(bytes calldata signature) 
        internal 
        pure 
        returns (bytes32 r, bytes32 s, uint8 v) 
    {
        require(signature.length >= 65, "SuperPaymaster: invalid signature length");
        
        // 前32字节是r
        r = bytes32(signature[0:32]);
        // 接下来32字节是s
        s = bytes32(signature[32:64]);
        // 最后1字节是v
        v = uint8(signature[64]);
        
        return (r, s, v);
    }
    
    /**
     * @notice Parse paymasterAndData
     * @dev 适应测试用例的格式，简化解析逻辑
     */
    function _parsePaymasterAndData(bytes calldata paymasterAndData, uint256 offset)
        internal
        pure
        returns (uint8 mode, bool allowAllBundlers, bytes calldata paymasterConfig)
    {
        require(paymasterAndData.length > offset, "SuperPaymaster: invalid paymasterAndData");
        
        bytes1 modeAndFlags = paymasterAndData[offset];
        mode = uint8(modeAndFlags >> 1);
        allowAllBundlers = (uint8(modeAndFlags) & 1) == 1;
        paymasterConfig = paymasterAndData[offset + 1:];
        
        return (mode, allowAllBundlers, paymasterConfig);
    }

    /**
     * @notice Override of the IPaymasterV7's postOp function
     * @dev This function intercepts the postOp call and implements SuperPaymaster specific logic
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    )
        external
        override
    {
        _requireFromEntryPoint();
        
        // First attempt to decode as sponsor context (no try/catch needed anymore)
        if (context.length > 0) {
            try this.decodeSponsorContext(context) returns (
                address sponsor,
                address token,
                uint256 maxEthCost,
                uint256 maxErc20Cost,
                bytes32 userOpHash
            ) {
                // Successfully decoded as sponsor context
                postOpSponsor(mode, sponsor, token, maxEthCost, maxErc20Cost, userOpHash, actualGasCost);
                return;
            } catch {
                // Not a sponsor context, delegate to singletonPaymaster
            }
        }
        
        // For other modes or if decoding failed, delegate to singletonPaymaster
        singletonPaymaster.postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    /**
     * @notice External function to decode sponsor context (used in try/catch)
     * @dev This is called internally via this.decodeSponsorContext() for error handling
     */
    function decodeSponsorContext(bytes calldata context) external pure returns (
        address sponsor,
        address token,
        uint256 maxEthCost,
        uint256 maxErc20Cost,
        bytes32 userOpHash
    ) {
        return abi.decode(context, (address, address, uint256, uint256, bytes32));
    }

    /**
     * @notice Handle postOp for sponsor mode
     */
    function postOpSponsor(
        PostOpMode mode,
        address sponsor,
        address token,
        uint256 maxEthCost,
        uint256 /*maxErc20Cost*/,
        bytes32 userOpHash,
        uint256 actualGasCost
    ) internal {
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        
        // Always unlock the funds that were locked in validateSponsorUserOp
        uint256 lockedAmount = stake.userOpLocks[userOpHash];
        if (lockedAmount > 0) {
            stake.lockedAmount -= lockedAmount;
            delete stake.userOpLocks[userOpHash];
            emit StakeUnlocked(sponsor, userOpHash, lockedAmount);
        }
        
        // Mark operation as processed to prevent replay
        processedOps[userOpHash] = true;
        
        // Only process payment if operation succeeded
        if (mode != PostOpMode.opSucceeded) {
            return;
        }

        // Verify actualGasCost doesn't exceed estimated max
        require(actualGasCost <= maxEthCost, "SuperPaymaster: actual cost exceeds max");
        
        // Verify sponsor still has enough stake
        require(
            stake.stakedAmount >= actualGasCost,
            "SuperPaymaster: insufficient sponsor stake post-validation"
        );
        
        // Deduct the actual gas cost from sponsor's stake
        stake.stakedAmount -= actualGasCost;
        
        // Emit sponsorship success event
        emit SponsorshipSuccess(userOpHash, sponsor, token, actualGasCost);
        
        // Check if balance is below warning threshold
        if (stake.stakedAmount < sponsorConfigs[sponsor].warningThreshold) {
            emit StakeWarning(sponsor, stake.stakedAmount);
        }
    }

    /**
     * @notice Add a bundler to the allowlist
     * @param bundler Address of the bundler to allow
     */
    function addBundler(address bundler) external onlyAdminOrManager {
        isBundlerAllowed[bundler] = true;
        emit BundlerAllowlistUpdated(bundler, true);
    }

    /**
     * @dev Define this to disable initializers for the implementation
     */
    function _disableInitializers() internal {}

    /**
     * @notice Require the sender to be the EntryPoint
     */
    function _requireFromEntryPoint() internal view {
        require(msg.sender == entryPoint, "SuperPaymaster: only EntryPoint");
    }
} 