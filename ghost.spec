ghost bool called_extcall;
ghost bool g_reverted;
ghost uint32 g_sighhash;

// Hook on "CALL" opcodes to simulate reentrancy to non-view functions
hook CALL(uint g, address addr, uint value, uint argsOffset, uint argsLength, uint retOffset, uint retLength) uint rc {
    called_extcall = true;
    env e;
    bool cond;
    if (g_sighhash == sig:upgradeTo(address).selector) {
        calldataarg args;
        upgradeTo@withrevert(e, args);
        g_reverted = lastReverted;
    }
    else if (g_sighhash == sig:upgradeToAndCall(address,bytes).selector) {
        calldataarg args;
        upgradeToAndCall@withrevert(e, args);
        g_reverted = lastReverted;
    }
    else if (g_sighhash == sig:changeAdmin(address).selector) {
        calldataarg args;
        changeAdmin@withrevert(e, args);
        g_reverted = lastReverted;
    }
    else {
        // fallback case
        g_reverted = true;
    }
}

// Main rule to check for reentrancy vulnerabilities
rule no_reentrancy(method f, method g) filtered {f -> !f.isView, g -> !g.isView} {
    require !called_extcall;
    require !g_reverted;
    env e; calldataarg args;
    require g_sighhash == g.selector;
    f@withrevert(e, args);

    // Main assertion: expect that if an external function is called,
    // any reentrancy to a non-view function will revert
    assert called_extcall => g_reverted;
}

// Additional rule to check admin consistency during potential reentrancy
rule admin_consistency_during_reentrancy(method f) filtered {f -> !f.isView} {
    env e; calldataarg args;
    address admin_before = _getAdmin();
    f@withrevert(e, args);
    address admin_after = _getAdmin();

    assert admin_before == admin_after, "Admin should not change during potential reentrancy";
}

// Rule to verify that only admin can call critical functions
rule only_admin_can_call_critical_functions(method f) filtered {
    f -> f.selector == sig:upgradeTo(address).selector ||
         f.selector == sig:upgradeToAndCall(address,bytes).selector ||
         f.selector == sig:changeAdmin(address).selector
} {
    env e; calldataarg args;
    require e.msg.sender != _getAdmin();
    f@withrevert(e, args);
    assert lastReverted, "Non-admin should not be able to call critical functions";
}
