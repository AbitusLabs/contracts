// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract QuoteDigestHelper {
    bytes32 public constant QUOTE_TYPEHASH =
        keccak256("Quote(uint256 epochId,uint256 notional,uint256 premium,uint256 expiry)");
    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    function getDigest(
        address verifyingContract,
        uint256 chainId,
        uint256 epochId,
        uint256 notional,
        uint256 premium,
        uint256 expiry
    ) external pure returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("AbitusLongGammaQuote"), keccak256("1"), chainId, verifyingContract)
        );
        bytes32 structHash = keccak256(abi.encode(QUOTE_TYPEHASH, epochId, notional, premium, expiry));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
