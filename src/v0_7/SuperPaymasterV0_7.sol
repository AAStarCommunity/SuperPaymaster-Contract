// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { _packValidationData } from "@account-abstraction-v7/core/Helpers.sol";
import { UserOperationLib } from "@account-abstraction-v7/core/UserOperationLib.sol";

import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { MessageHashUtils } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";

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
contract SuperPaymasterV0_7 is SingletonPaymasterV7, ISuperPaymaster, ReentrancyGuard {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       STATE VARIABLES                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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

    /// @notice Event emitted when funds are locked for a UserOperation
    event StakeLocked(address indexed sponsor, bytes32 indexed userOpHash, uint256 amount);

    /// @notice Event emitted when locked funds are released
    event StakeUnlocked(address indexed sponsor, bytes32 indexed userOpHash, uint256 amount);

    /// @notice Error when attempting to withdraw more than available (non-locked) funds
    error InsufficientUnlockedStake(uint256 requested, uint256 available);

    /// @notice Error when a withdrawal request doesn't exist or is invalid
    error InvalidWithdrawalRequest();

    /// @notice Error when a withdrawal is still in the time lock period
    error WithdrawalStillLocked(uint256 unlockTime);

    /// @notice Error when a withdrawal has already been executed
    error WithdrawalAlreadyExecuted();

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
    ) SingletonPaymasterV7(_entryPoint, _owner, _manager, _signers) {}

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
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: not sponsor owner");
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
        entryPoint.depositTo{value: msg.value}(address(this));
        
        emit StakeDeposited(sponsor, msg.value);
    }

    /**
     * @inheritdoc ISuperPaymaster
     * @dev This is now a two-step process:
     * 1. Request withdrawal, which starts the time lock
     * 2. After time lock passes, execute the withdrawal using executeWithdrawal
     */
    function withdrawStake(uint256 amount) external override nonReentrant {
        address sponsor = msg.sender;
        require(isSponsor[sponsor], "SuperPaymaster: not a sponsor");
        require(msg.sender == sponsorConfigs[sponsor].owner, "SuperPaymaster: not sponsor owner");
        require(amount > 0, "SuperPaymaster: withdraw amount must be positive");
        
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        
        // Calculate available (non-locked) amount
        uint256 availableAmount = stake.stakedAmount - stake.lockedAmount;
        
        // Check if there's enough available balance (not locked)
        if (amount > availableAmount) {
            revert InsufficientUnlockedStake(amount, availableAmount);
        }
        
        // Create a pending withdrawal request
        uint256 withdrawalId = nextWithdrawalId[sponsor];
        nextWithdrawalId[sponsor] = withdrawalId + 1;
        
        // Set unlock time according to withdrawal delay
        uint256 unlockTime = block.timestamp + withdrawalDelay;
        
        // Store withdrawal request
        pendingWithdrawals[sponsor][withdrawalId] = PendingWithdrawal({
            amount: amount,
            unlockTime: unlockTime,
            executed: false
        });
        
        // Reserve the funds by reducing the available amount
        stake.stakedAmount -= amount;
        
        emit WithdrawalRequested(sponsor, withdrawalId, amount, unlockTime);
    }

    /**
     * @notice Execute a previously requested withdrawal
     * @param withdrawalId ID of the withdrawal request to execute
     */
    function executeWithdrawal(uint256 withdrawalId) external nonReentrant {
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
        
        if (block.timestamp < withdrawal.unlockTime) {
            revert WithdrawalStillLocked(withdrawal.unlockTime);
        }
        
        // Mark as executed
        withdrawal.executed = true;
        
        // Execute the withdrawal
        uint256 amount = withdrawal.amount;
        entryPoint.withdrawTo(payable(sponsor), amount);
        
        emit WithdrawalExecuted(sponsor, withdrawalId, amount);
    }

    /**
     * @notice Cancel a pending withdrawal that has not been executed yet
     * @param withdrawalId ID of the withdrawal request to cancel
     */
    function cancelWithdrawal(uint256 withdrawalId) external nonReentrant {
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
        returns (
            uint256 amount, 
            uint256 unlockTime, 
            bool executed
        ) 
    {
        PendingWithdrawal storage withdrawal = pendingWithdrawals[sponsor][withdrawalId];
        return (withdrawal.amount, withdrawal.unlockTime, withdrawal.executed);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   PAYMASTER OPERATIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Override of the SingletonPaymasterV7 _validatePaymasterUserOp function
     * @dev Adds support for SPONSOR_MODE
     */
    function _validatePaymasterUserOp(
        PackedUserOperation calldata _userOp,
        bytes32 _userOpHash,
        uint256 _requiredPreFund
    ) internal override returns (bytes memory, uint256) {
        (uint8 mode, bool allowAllBundlers, bytes calldata paymasterConfig) =
            _parsePaymasterAndData(_userOp.paymasterAndData, UserOperationLib.PAYMASTER_DATA_OFFSET);

        if (!allowAllBundlers && !isBundlerAllowed[tx.origin]) {
            revert BundlerNotAllowed(tx.origin);
        }

        if (mode == SPONSOR_MODE) {
            return _validateSponsorMode(_userOp, paymasterConfig, _userOpHash, _requiredPreFund);
        }

        // For other modes, call the parent implementation
        return super._validatePaymasterUserOp(_userOp, _userOpHash, _requiredPreFund);
    }

    /**
     * @notice Validates a UserOperation when using the sponsor mode
     * @param _userOp The UserOperation
     * @param _paymasterConfig The encoded paymaster config from paymasterAndData
     * @param _userOpHash The UserOperation hash
     * @param _requiredPreFund The required prefund amount
     * @return context Context to be passed to postOp
     * @return validationData Packed validation data
     */
    function _validateSponsorMode(
        PackedUserOperation calldata _userOp,
        bytes calldata _paymasterConfig,
        bytes32 _userOpHash,
        uint256 _requiredPreFund
    ) internal returns (bytes memory context, uint256 validationData) {
        // Decode sponsor data from paymasterConfig
        (
            address sponsor,
            address token,
            uint256 maxErc20Cost,
            uint48 validUntil,
            uint48 validAfter,
            bytes calldata signature
        ) = _parseSponsorConfig(_paymasterConfig);
        
        // Verify sponsor is registered and enabled
        require(isSponsor[sponsor], "SuperPaymaster: invalid sponsor");
        require(sponsorConfigs[sponsor].isEnabled, "SuperPaymaster: sponsor not enabled");
        
        // Verify token matches the sponsor's configured token
        require(token == sponsorConfigs[sponsor].token, "SuperPaymaster: token mismatch");
        
        // Get the sponsor's configured signer
        address signer = sponsorConfigs[sponsor].signer;
        
        // Create the message hash for signature verification
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(
            _getSponsorHash(_userOp, _userOpHash, sponsor, token, maxErc20Cost, validUntil, validAfter)
        );
        
        // Verify signature
        address recoveredSigner = ECDSA.recover(hash, signature);
        bool isSignatureValid = (recoveredSigner == signer);
        
        // Calculate maximum ETH cost based on exchange rate
        uint256 exchangeRate = sponsorConfigs[sponsor].exchangeRate;
        require(exchangeRate > 0, "SuperPaymaster: invalid exchange rate");
        
        // Calculate maxEthCost: (maxErc20Cost * 1 ether) / exchangeRate
        uint256 maxEthCost = (maxErc20Cost * 1 ether) / exchangeRate;
        
        // Get sponsor stake
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        
        // Ensure sponsor has enough total stake
        require(
            stake.stakedAmount >= maxEthCost,
            "SuperPaymaster: insufficient sponsor stake"
        );

        // Lock funds for this operation if signature is valid
        if (isSignatureValid) {
            // Check if already locked for this userOpHash (prevent double-validation)
            if (stake.userOpLocks[_userOpHash] == 0) {
                stake.lockedAmount += maxEthCost;
                stake.userOpLocks[_userOpHash] = maxEthCost;
                emit StakeLocked(sponsor, _userOpHash, maxEthCost);
            }
        }
        
        // Pack validation data (signature validity and timestamps)
        validationData = _packValidationData(!isSignatureValid, validUntil, validAfter);
        
        // Encode context for postOp
        context = abi.encode(sponsor, token, maxEthCost, maxErc20Cost, _userOpHash);
        
        emit UserOperationSponsored(_userOpHash, _userOp.getSender(), SPONSOR_MODE, token, maxErc20Cost, maxEthCost);
        
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
        // Expected format:
        // - validUntil (6 bytes)
        // - validAfter (6 bytes)
        // - sponsor address (20 bytes)
        // - token address (20 bytes)
        // - maxErc20Cost (32 bytes)
        // - signature (65 bytes)
        
        uint256 offset = 0;
        
        validUntil = uint48(bytes6(_paymasterConfig[offset:offset + 6]));
        offset += 6;
        
        validAfter = uint48(bytes6(_paymasterConfig[offset:offset + 6]));
        offset += 6;
        
        sponsor = address(bytes20(_paymasterConfig[offset:offset + 20]));
        offset += 20;
        
        token = address(bytes20(_paymasterConfig[offset:offset + 20]));
        offset += 20;
        
        maxErc20Cost = uint256(bytes32(_paymasterConfig[offset:offset + 32]));
        offset += 32;
        
        signature = _paymasterConfig[offset:];
        
        return (sponsor, token, maxErc20Cost, validUntil, validAfter, signature);
    }

    /**
     * @notice Create hash for sponsor signature verification
     */
    function _getSponsorHash(
        PackedUserOperation calldata _userOp,
        bytes32 _userOpHash,
        address sponsor,
        address token,
        uint256 maxErc20Cost,
        uint48 validUntil,
        uint48 validAfter
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _userOpHash,
                address(this), // Paymaster address
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
     * @notice Override of the SingletonPaymasterV7 _postOp function
     * @dev Adds support for SPONSOR_MODE
     */
    function _postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) internal override {
        // Check if this is a sponsor mode context by attempting to decode
        if (context.length > 0) {
            try this.decodeSponsorContext(context) returns (
                address sponsor,
                address token,
                uint256 maxEthCost,
                uint256 maxErc20Cost,
                bytes32 userOpHash
            ) {
                // This is a sponsor context, handle it specifically
                _postOpSponsor(mode, sponsor, token, maxEthCost, maxErc20Cost, userOpHash, actualGasCost);
                return;
            } catch {
                // Not a sponsor context, continue with base implementation
            }
        }

        // For other modes, call the parent implementation
        super._postOp(mode, context, actualGasCost, actualUserOpFeePerGas);
    }

    /**
     * @notice External function to decode sponsor context (used in try/catch)
     * @dev This is called internally via this.decodeSponsorContext() for error handling
     */
    function decodeSponsorContext(bytes calldata context) external view returns (
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
    function _postOpSponsor(
        PostOpMode mode,
        address sponsor,
        address token,
        uint256 maxEthCost,
        uint256 maxErc20Cost,
        bytes32 userOpHash,
        uint256 actualGasCost
    ) internal {
        EnhancedSponsorStake storage stake = sponsorStakes[sponsor];
        
        // Always unlock the funds that were locked in validatePaymasterUserOp
        uint256 lockedAmount = stake.userOpLocks[userOpHash];
        if (lockedAmount > 0) {
            stake.lockedAmount -= lockedAmount;
            delete stake.userOpLocks[userOpHash];
            emit StakeUnlocked(sponsor, userOpHash, lockedAmount);
        }
        
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
} 