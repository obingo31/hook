// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import "../src/Proxy.sol";

contract MockImplementation {
    uint256 public value;
    function setValue(uint256 _value) public {
        value = _value;
    }
    function revertingFunction() public pure {
        revert("This function always reverts");
    }
    receive() external payable {}
    fallback() external payable {}
}

contract ProxyTest is Test {
    Proxy public proxy;
    MockImplementation public implementation;
    address public admin;
    address public user;

    event Upgraded(address indexed implementation);
    event AdminChanged(address previousAdmin, address newAdmin);

    function setUp() public {
        admin = address(this);
        user = address(0x1);
        proxy = new Proxy(admin);
        implementation = new MockImplementation();
    }

    function testAdminAccessControl() public {
        // Test admin functions
        proxy.upgradeTo(address(implementation));
        proxy.changeAdmin(address(0x2));
        
        // Test non-admin access
        vm.prank(user);
        vm.expectRevert();
        proxy.upgradeTo(address(implementation));

        vm.prank(user);
        vm.expectRevert();
        proxy.changeAdmin(address(0x3));
    }

    function testImplementationAddressIntegrity() public {
        // Test setting implementation
        vm.expectEmit(true, false, false, true);
        emit Upgraded(address(implementation));
        proxy.upgradeTo(address(implementation));

        // Verify implementation address
        assertEq(proxy.implementation(), address(implementation));

        // Test setting zero address (should not revert, but should not change the implementation)
        proxy.upgradeTo(address(0));
        assertEq(proxy.implementation(), address(implementation));

        // Test setting implementation as non-admin (should be proxied to implementation)
        address newImpl = address(new MockImplementation());
        vm.prank(user);
        (bool success,) = address(proxy).call(abi.encodeWithSelector(Proxy.upgradeTo.selector, newImpl));
        assertTrue(success);
        assertEq(proxy.implementation(), address(implementation)); // Implementation should not change
    }

    function testProxyFunctionality() public {
        proxy.upgradeTo(address(implementation));

        // Test forwarding calls
        MockImplementation(address(proxy)).setValue(42);
        assertEq(MockImplementation(address(proxy)).value(), 42);

        // Test reverting calls
        vm.expectRevert("This function always reverts");
        MockImplementation(address(proxy)).revertingFunction();
    }

    function testUpgradeAtomicity() public {
        // Prepare calldata for setValue(100)
        bytes memory data = abi.encodeWithSelector(MockImplementation.setValue.selector, 100);

        // Upgrade and call in single transaction
        proxy.upgradeToAndCall(address(implementation), data);

        // Verify upgrade and call effects
        assertEq(proxy.implementation(), address(implementation));
        assertEq(MockImplementation(address(proxy)).value(), 100);
    }

    function testEventEmission() public {
        // Test Upgraded event
        vm.expectEmit(true, false, false, true);
        emit Upgraded(address(implementation));
        proxy.upgradeTo(address(implementation));

        // Test AdminChanged event
        address newAdmin = address(0x4);
        vm.expectEmit(true, true, false, true);
        emit AdminChanged(admin, newAdmin);
        proxy.changeAdmin(newAdmin);
    }

    function testReceiveAndFallback() public {
        proxy.upgradeTo(address(implementation));

        // Test receive function
        (bool success,) = address(proxy).call{value: 1 ether}("");
        assertTrue(success);

        // Test fallback function
        (success,) = address(proxy).call(abi.encodeWithSignature("nonExistentFunction()"));
        assertTrue(success);
    }

    function testGasLimitHandling() public {
        proxy.upgradeTo(address(implementation));

        // Test with low gas limit
        (bool success,) = address(proxy).call{gas: 1000}(abi.encodeWithSelector(MockImplementation.setValue.selector, 42));
        assertFalse(success);
    }

    receive() external payable {}
}
