// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/core/implement_optiontokensol__erc_.sol";

contract UimplementUoptiontokensol_Uerc_Test is Test {
    UimplementUoptiontokensol_Uerc_ public instance;

    function setUp() public {
        instance = new UimplementUoptiontokensol_Uerc_();
    }

    function test_version() public view {
        assertEq(instance.VERSION(), "0.1.0");
    }

    function test_placeholder() public view {
        assertTrue(instance.placeholder());
    }
}
