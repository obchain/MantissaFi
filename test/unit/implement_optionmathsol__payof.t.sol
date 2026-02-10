// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/implement_optionmathsol__payof.sol";

contract UimplementUoptionmathsol_UpayofTest is Test {
    UimplementUoptionmathsol_Upayof public instance;

    function setUp() public {
        instance = new UimplementUoptionmathsol_Upayof();
    }

    function test_version() public view {
        assertEq(instance.VERSION(), "0.1.0");
    }

    function test_placeholder() public view {
        assertTrue(instance.placeholder());
    }
}
