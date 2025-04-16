// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISuperPaymaster
 * @dev Interface for SuperPaymaster with multi-sponsor support
 * This interface extends the standard ERC-4337 Paymaster functions with sponsor management
 */
interface ISuperPaymaster {
    /**
     * @dev Represents a sponsor's configuration
     * @param owner The address that can modify this sponsor's configuration
     * @param token The ERC20 token address accepted for gas payments
     * @param exchangeRate Fixed exchange rate (token wei per 1 ETH wei)
     * @param warningThreshold ETH balance threshold for low-balance warnings
     * @param isEnabled Whether this sponsor configuration is active
     * @param signer Address authorized to sign paymaster operations for this sponsor
     */
    struct SponsorConfig {
        address owner;
        address token;
        uint256 exchangeRate;
        uint256 warningThreshold;
        bool isEnabled;
        address signer;
    }

    /**
     * @dev Represents a sponsor's stake information (simplified view)
     * @param stakedAmount Amount of ETH staked by the sponsor (in wei)
     */
    struct SponsorStake {
        uint256 stakedAmount;
    }

    /**
     * @dev Represents a pending withdrawal request
     * @param amount Amount requested for withdrawal
     * @param unlockTime Time when withdrawal can be executed
     * @param executed Whether the withdrawal has been executed
     */
    struct PendingWithdrawal {
        uint256 amount;
        uint256 unlockTime;
        bool executed;
    }

    /**
     * @dev Registers a new sponsor
     * @param sponsor Address of the sponsor to register
     * @notice Only callable by contract admin or manager
     */
    function registerSponsor(address sponsor) external;

    /**
     * @dev Configures a sponsor's parameters
     * @param token ERC20 token address accepted for payments
     * @param exchangeRate Fixed exchange rate (token wei per 1 ETH wei)
     * @param warningThreshold ETH balance threshold for low-balance warnings
     * @param signer Address authorized to sign paymaster operations
     * @notice Only callable by the sponsor or its owner
     */
    function setSponsorConfig(
        address token,
        uint256 exchangeRate,
        uint256 warningThreshold,
        address signer
    ) external;

    /**
     * @dev Enables or disables a sponsor
     * @param enabled Whether to enable or disable the sponsor
     * @notice Only callable by the sponsor or its owner
     */
    function enableSponsor(bool enabled) external;

    /**
     * @dev Deposits ETH to the sponsor's stake
     * @notice Payable function, sent ETH is added to sponsor's stake
     */
    function depositStake() external payable;

    /**
     * @dev Initiates a withdrawal request for ETH from the sponsor's stake
     * @param amount Amount of ETH to withdraw (in wei)
     * @notice Only callable by the sponsor or its owner
     * @notice Only unlocked (non-pending) funds can be withdrawn
     * @notice This starts a time-lock period before funds can be withdrawn
     */
    function withdrawStake(uint256 amount) external;

    /**
     * @dev Executes a previously requested withdrawal after the time-lock period
     * @param withdrawalId ID of the withdrawal request to execute
     * @notice Only callable by the sponsor or its owner
     */
    function executeWithdrawal(uint256 withdrawalId) external;

    /**
     * @dev Cancels a pending withdrawal that has not been executed yet
     * @param withdrawalId ID of the withdrawal request to cancel
     * @notice Only callable by the sponsor or its owner
     */
    function cancelWithdrawal(uint256 withdrawalId) external;

    /**
     * @dev Gets details of a pending withdrawal
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
        );

    /**
     * @dev Returns the current sponsor config
     * @param sponsor Address of the sponsor
     * @return SponsorConfig struct with the sponsor's configuration
     */
    function getSponsorConfig(address sponsor) external view returns (SponsorConfig memory);

    /**
     * @dev Returns the current sponsor stake
     * @param sponsor Address of the sponsor
     * @return uint256 Amount of ETH staked by the sponsor (in wei)
     */
    function getSponsorStake(address sponsor) external view returns (uint256);

    // Events
    event SponsorRegistered(address indexed sponsor);
    event SponsorConfigSet(address indexed sponsor, address indexed token, uint256 exchangeRate, uint256 warningThreshold, address signer);
    event SponsorEnabled(address indexed sponsor, bool enabled);
    event StakeDeposited(address indexed sponsor, uint256 amount);
    event StakeWithdrawn(address indexed sponsor, uint256 amount);
    event WithdrawalRequested(address indexed sponsor, uint256 indexed withdrawalId, uint256 amount, uint256 unlockTime);
    event WithdrawalExecuted(address indexed sponsor, uint256 indexed withdrawalId, uint256 amount);
    event SponsorshipSuccess(bytes32 indexed userOpHash, address indexed sponsor, address indexed token, uint256 actualGasCost);
    event StakeWarning(address indexed sponsor, uint256 currentStake);
} 