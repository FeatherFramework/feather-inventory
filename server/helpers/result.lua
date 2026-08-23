-- (INV-W1) Shared result envelope, per DEPENDENCY_SUPPORT_PLAN §3.1.
--
--   { ok = true,  value = <result>, correlationId = <id> }
--   { ok = false, error = { code = 'STABLE_CODE', message = '...', details = {} }, correlationId = <id> }
--
-- EXTENDS rather than replaces the existing shapes. This resource currently
-- returns at least three different things for a failure -- bare `false`, bare
-- `nil`, `-1`, and `{ error = true, message = ... }` -- and rewriting every
-- existing export to this envelope in one pass would break every consumer at
-- once for no immediate gain. New contract surfaces (InstancesAPI and
-- everything INV-W2..W4 adds) use this; older functions keep their shapes
-- until there is a reason to touch them. MASTER_PLAN §3 explicitly allows
-- that incremental path.
--
-- The distinction the plan cares about is that `code` is STABLE and
-- machine-readable while `message` is developer-facing English -- the same
-- separation the err_<code> locale keys already rely on, so a caller can
-- localize or branch on `code` without pattern-matching prose.
Result = {}

-- Stable error codes. Kept in one table so a consumer can compare against
-- Result.Codes.CONFLICT rather than a bare string literal, and so the full
-- vocabulary is discoverable in one place.
Result.Codes = {
    INVALID_INPUT      = 'invalid_input',      -- caller passed something malformed
    NOT_FOUND          = 'not_found',          -- referenced entity does not exist
    DENIED             = 'denied',             -- caller may not do this
    CONFLICT           = 'conflict',           -- optimistic-concurrency failure (revision mismatch)
    UNSUPPORTED        = 'unsupported',        -- valid request, not supported for this entity
    LIMIT_EXCEEDED     = 'limit_exceeded',     -- capacity / weight / quantity
    DEPENDENCY_MISSING = 'dependency_missing', -- a required capability is absent
    INTERNAL           = 'internal',           -- unexpected failure
}

---
-- Ok
--
-- @param value Payload (may be nil for operations with no return value)
-- @param correlationId Optional id threaded through from a mutation context
-- @return Success envelope
--
function Result.Ok(value, correlationId)
    return { ok = true, value = value, correlationId = correlationId }
end

---
-- Err
--
-- @param code One of Result.Codes (or a domain-specific stable string)
-- @param message Developer-facing English; not shown to players directly
-- @param details Optional table of structured context
-- @param correlationId Optional id threaded through from a mutation context
-- @return Failure envelope
--
function Result.Err(code, message, details, correlationId)
    return {
        ok = false,
        error = {
            code = code or Result.Codes.INTERNAL,
            message = message or 'Unexpected failure.',
            details = details or {}
        },
        correlationId = correlationId
    }
end

---
-- IsOk
--
-- Guards against the easy mistake of testing an envelope for truthiness --
-- a failure envelope is itself a non-nil table, so `if SomeCall() then` is
-- always true and silently treats every error as success.
--
function Result.IsOk(result)
    return type(result) == 'table' and result.ok == true
end
