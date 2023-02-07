// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

library Arrays {
    function deleteElement(address[] storage self, address element) internal {
        uint256 count = self.length;
        for (uint256 i = 0; i < count;) {
            if (self[i] == element && i != count - 1) {
                self[i] = self[count - 1];
                self.pop();
                break;
            }

            unchecked {
                i++;
            }
        }
    }
}