// SPDX-License-Identifier: MIT
pragma solidity =0.8.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Token is ERC20 {

    constructor(string memory name_, string memory symbol_)
        ERC20(name_, symbol_) {
        _mint(msg.sender, (100000 * 1e18)); 
    }

    function mint(uint256 amount) external {
        _mint(msg.sender, amount);
    }
}












