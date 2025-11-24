# Verify we can spawn multiple bootc status at the same time
use std assert
use tap.nu

tap begin "concurrent bootc status"

# Fork via systemd-run
let n = 10
0..$n | each { |v|
    # Clean up prior runs
    systemctl stop $"bootc-status-($v)" | complete
}
# Fork off a concurrent bootc status
0..$n | each { |v|
    systemd-run --no-block -qr -u $"bootc-status-($v)" bootc status
}

# Await completion
0..$n | each { |v|
    loop {
        let r = systemctl is-active $"bootc-status-($v)" | complete
        if $r.exit_code == 0 {
            break
        }
        # check status
        systemctl status $"bootc-status-($v)" out> /dev/null
        # Clean it up
        systemctl reset-failed $"bootc-status-($v)"
    }
}

tap ok
