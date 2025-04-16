// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PaymasterHelpers
 * @notice Helper functions for working with Paymaster data
 */
library PaymasterHelpers {
    /**
     * @notice Decode sponsor ID from paymasterAndData
     * @param paymasterAndData The paymasterAndData field from a UserOperation
     * @return sponsorId The decoded sponsor ID
     */
    function decodeSponsorId(bytes memory paymasterAndData) internal pure returns (bytes memory) {
        require(paymasterAndData.length >= 33, "Invalid paymasterAndData length");
        
        // Mode is stored in the first byte (shifted right by 1)
        uint8 mode = uint8(uint8(paymasterAndData[0]) >> 1);
        
        // For sponsor mode (1), extract the sponsor address which comes after the mode byte
        if (mode == 1) {
            // The sponsor address starts at 6+6 (validUntil + validAfter) + 1 (mode byte) = 13
            bytes memory sponsorBytes = new bytes(20);
            for (uint i = 0; i < 20; i++) {
                sponsorBytes[i] = paymasterAndData[13 + i];
            }
            return sponsorBytes;
        }
        
        // Return empty bytes if not in sponsor mode
        return new bytes(0);
    }
    
    /**
     * @notice Parse sponsor config from paymasterAndData
     * @param paymasterAndData The paymasterAndData field from a UserOperation
     * @return sponsor The sponsor address
     * @return token The token address for ERC20 payments
     * @return maxErc20Cost The maximum ERC20 cost allowed
     * @return validUntil The timestamp until which the signature is valid
     * @return validAfter The timestamp after which the signature is valid
     * @return signature The sponsor's signature
     */
    function parseSponsorConfig(bytes memory paymasterAndData)
        internal
        pure
        returns (
            address sponsor,
            address token,
            uint256 maxErc20Cost,
            uint48 validUntil,
            uint48 validAfter,
            bytes memory signature
        )
    {
        require(paymasterAndData.length >= 114, "Invalid config length"); // 1+6+6+20+20+32+min(29)
        
        uint256 offset = 1; // Skip the mode byte
        
        // Extract validUntil (6 bytes)
        validUntil = _extractUint48(paymasterAndData, offset);
        offset += 6;
        
        // Extract validAfter (6 bytes)
        validAfter = _extractUint48(paymasterAndData, offset);
        offset += 6;
        
        // Extract sponsor address (20 bytes)
        sponsor = _extractAddress(paymasterAndData, offset);
        offset += 20;
        
        // Extract token address (20 bytes)
        token = _extractAddress(paymasterAndData, offset);
        offset += 20;
        
        // Extract maxErc20Cost (32 bytes)
        maxErc20Cost = _extractUint256(paymasterAndData, offset);
        offset += 32;
        
        // Extract signature (remaining bytes)
        signature = new bytes(paymasterAndData.length - offset);
        for (uint i = 0; i < signature.length; i++) {
            signature[i] = paymasterAndData[offset + i];
        }
        
        return (sponsor, token, maxErc20Cost, validUntil, validAfter, signature);
    }
    
    /**
     * @notice Parse paymasterAndData to extract mode, bundler flag, and config
     * @param paymasterAndData The paymasterAndData field from a UserOperation
     * @return mode Operation mode (0: verifying, 1: sponsor)
     * @return allowAllBundlers Flag indicating if all bundlers are allowed
     * @return paymasterConfig Configuration data excluding mode byte
     */
    function parsePaymasterAndData(bytes memory paymasterAndData)
        internal
        pure
        returns (uint8 mode, bool allowAllBundlers, bytes memory paymasterConfig)
    {
        require(paymasterAndData.length > 0, "Invalid paymasterAndData");
        
        bytes1 modeAndFlags = paymasterAndData[0];
        mode = uint8(uint8(modeAndFlags) >> 1);
        allowAllBundlers = (uint8(modeAndFlags) & 1) == 1;
        
        paymasterConfig = new bytes(paymasterAndData.length - 1);
        for (uint i = 0; i < paymasterConfig.length; i++) {
            paymasterConfig[i] = paymasterAndData[1 + i];
        }
        
        return (mode, allowAllBundlers, paymasterConfig);
    }
    
    /**
     * @notice Helper to extract a uint48 from bytes
     */
    function _extractUint48(bytes memory data, uint256 offset) private pure returns (uint48 result) {
        require(offset + 6 <= data.length, "Out of bounds");
        uint256 value;
        for (uint i = 0; i < 6; i++) {
            value = value << 8;
            value |= uint8(data[offset + i]);
        }
        return uint48(value);
    }
    
    /**
     * @notice Helper to extract an address from bytes
     */
    function _extractAddress(bytes memory data, uint256 offset) private pure returns (address result) {
        require(offset + 20 <= data.length, "Out of bounds");
        uint160 addr;
        for (uint i = 0; i < 20; i++) {
            addr = addr << 8;
            addr |= uint8(data[offset + i]);
        }
        return address(addr);
    }
    
    /**
     * @notice Helper to extract a uint256 from bytes
     */
    function _extractUint256(bytes memory data, uint256 offset) private pure returns (uint256 result) {
        require(offset + 32 <= data.length, "Out of bounds");
        for (uint i = 0; i < 32; i++) {
            result = result << 8;
            result |= uint8(data[offset + i]);
        }
        return result;
    }
} 