-- SPDX-License-Identifier: MIT
-- harness-steps: fixture_ping
-- A minimal Lua extension for the self-test: one driver step that only reports a value.

return {
    fixture_ping = function(h)
        h.put("pong", 1)
    end,
}
