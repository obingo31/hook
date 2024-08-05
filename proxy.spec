methods {
    _getAdmin() returns (address) envfree
    _doProxyCall() => NONDET
}

// Ghost variable to track if _doProxyCall was called
ghost bool doProxyCallInvoked;

// Hook to update the ghost variable when _doProxyCall is invoked
hook Sload _doProxyCall() STORAGE {
    doProxyCallInvoked = true;
}

// Rule to test admin call behavior
rule testAdminCall(method f, env e) {
    require e.msg.sender == _getAdmin();
    
    // Save the state before the call
    env eOrig = e;
    bool doProxyCallInvokedOrig = doProxyCallInvoked;

    // Call any function with the modifier
    f(e);

    // Check that _doProxyCall was not invoked
    assert doProxyCallInvoked == doProxyCallInvokedOrig, "Admin call should not invoke _doProxyCall";
}

// Rule to test zero address call behavior
rule testZeroAddressCall(method f, env e) {
    require e.msg.sender == 0;
    
    env eOrig = e;
    bool doProxyCallInvokedOrig = doProxyCallInvoked;

    f(e);

    assert doProxyCallInvoked == doProxyCallInvokedOrig, "Zero address call should not invoke _doProxyCall";
}

// Rule to test non-admin call behavior
rule testNonAdminCall(method f, env e) {
    require e.msg.sender != _getAdmin() && e.msg.sender != 0;
    
    env eOrig = e;
    bool doProxyCallInvokedOrig = doProxyCallInvoked;

    f(e);

    assert doProxyCallInvoked != doProxyCallInvokedOrig, "Non-admin call should invoke _doProxyCall";
}

// Invariant to ensure only non-admin calls invoke _doProxyCall
invariant proxyCallConsistency()
    doProxyCallInvoked => (lastSender != _getAdmin() && lastSender != 0)
