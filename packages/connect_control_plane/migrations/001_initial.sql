CREATE TABLE runtime_link_challenges (
    challenge_id text PRIMARY KEY CHECK (challenge_id ~ '^chl_[0-9a-f]{32}$'),
    request_id text NOT NULL CHECK (request_id ~ '^req_[0-9a-f]{32}$'),
    request_digest text NOT NULL,
    principal_issuer text NOT NULL,
    principal_subject text NOT NULL,
    runtime_id text NOT NULL CHECK (runtime_id ~ '^[0-9a-f]{32}$'),
    instance_id text NOT NULL CHECK (instance_id ~ '^[0-9a-f]{32}$'),
    runtime_signing_jwk jsonb NOT NULL,
    runtime_key_thumbprint text NOT NULL,
    runtime_encryption_jwk jsonb NOT NULL,
    runtime_encryption_key_thumbprint text NOT NULL,
    nonce text NOT NULL,
    nonce_hash text NOT NULL,
    audience text NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL,
    consumed_at timestamptz,
    proof_digest text,
    link_id text,
    UNIQUE (principal_issuer, principal_subject, request_id),
    CHECK ((consumed_at IS NULL AND proof_digest IS NULL AND link_id IS NULL) OR
           (consumed_at IS NOT NULL AND proof_digest IS NOT NULL AND link_id IS NOT NULL))
);

CREATE TABLE runtime_links (
    link_id text PRIMARY KEY CHECK (link_id ~ '^lnk_[0-9a-f]{32}$'),
    challenge_id text NOT NULL UNIQUE REFERENCES runtime_link_challenges(challenge_id),
    principal_issuer text NOT NULL,
    principal_subject text NOT NULL,
    runtime_id text NOT NULL CHECK (runtime_id ~ '^[0-9a-f]{32}$'),
    instance_id text NOT NULL CHECK (instance_id ~ '^[0-9a-f]{32}$'),
    runtime_signing_jwk jsonb NOT NULL,
    runtime_key_thumbprint text NOT NULL,
    runtime_encryption_jwk jsonb NOT NULL,
    runtime_encryption_key_thumbprint text NOT NULL,
    descriptor jsonb,
    status text NOT NULL CHECK (status IN ('linked', 'unlinked')),
    created_at timestamptz NOT NULL,
    unlinked_at timestamptz
);

CREATE UNIQUE INDEX runtime_links_one_active_runtime
    ON runtime_links(principal_issuer, principal_subject, runtime_id)
    WHERE status = 'linked';

ALTER TABLE runtime_link_challenges
    ADD CONSTRAINT runtime_link_challenges_link_id_fkey
    FOREIGN KEY (link_id) REFERENCES runtime_links(link_id) DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE endpoint_enrollments (
    enrollment_id text PRIMARY KEY CHECK (enrollment_id ~ '^enr_[0-9a-f]{32}$'),
    request_id text NOT NULL CHECK (request_id ~ '^req_[0-9a-f]{32}$'),
    request_digest text NOT NULL,
    link_id text NOT NULL REFERENCES runtime_links(link_id),
    principal_issuer text NOT NULL,
    principal_subject text NOT NULL,
    provider text NOT NULL CHECK (provider IN ('external', 'noop_test')),
    descriptor jsonb,
    status text NOT NULL CHECK (status IN ('pending', 'active', 'revoked')),
    secret_verifier text,
    secret_expires_at timestamptz,
    created_at timestamptz NOT NULL,
    activated_at timestamptz,
    revoked_at timestamptz,
    UNIQUE (principal_issuer, principal_subject, request_id),
    CHECK ((status = 'pending' AND descriptor IS NULL AND activated_at IS NULL AND revoked_at IS NULL) OR
           (status = 'active' AND descriptor IS NOT NULL AND activated_at IS NOT NULL AND revoked_at IS NULL) OR
           (status = 'revoked' AND descriptor IS NULL AND revoked_at IS NOT NULL))
);

CREATE UNIQUE INDEX endpoint_enrollments_one_active_link
    ON endpoint_enrollments(link_id)
    WHERE status = 'active';

CREATE TABLE connect_devices (
    principal_issuer text NOT NULL,
    principal_subject text NOT NULL,
    device_id text NOT NULL CHECK (device_id ~ '^dev_[0-9a-f]{32}$'),
    device_signing_jwk jsonb NOT NULL,
    device_key_thumbprint text NOT NULL,
    status text NOT NULL CHECK (status IN ('active', 'revoked')),
    created_at timestamptz NOT NULL,
    revoked_at timestamptz,
    PRIMARY KEY (principal_issuer, principal_subject, device_id),
    CHECK ((status = 'active' AND revoked_at IS NULL) OR
           (status = 'revoked' AND revoked_at IS NOT NULL))
);

CREATE TABLE bootstrap_grants (
    grant_id text PRIMARY KEY CHECK (grant_id ~ '^grt_[0-9a-f]{32}$'),
    request_id text NOT NULL CHECK (request_id ~ '^req_[0-9a-f]{32}$'),
    request_digest text NOT NULL,
    link_id text NOT NULL REFERENCES runtime_links(link_id),
    principal_issuer text NOT NULL,
    principal_subject text NOT NULL,
    runtime_id text NOT NULL CHECK (runtime_id ~ '^[0-9a-f]{32}$'),
    instance_id text NOT NULL CHECK (instance_id ~ '^[0-9a-f]{32}$'),
    device_id text NOT NULL CHECK (device_id ~ '^dev_[0-9a-f]{32}$'),
    device_signing_jwk jsonb NOT NULL,
    device_key_thumbprint text NOT NULL,
    audience text NOT NULL,
    client_nonce text NOT NULL,
    scopes text[] NOT NULL,
    issued_at_seconds bigint NOT NULL,
    expires_at_seconds bigint NOT NULL,
    created_at timestamptz NOT NULL,
    UNIQUE (principal_issuer, principal_subject, request_id)
);

CREATE TABLE revocations (
    revocation_id text PRIMARY KEY CHECK (revocation_id ~ '^rev_[0-9a-f]{32}$'),
    request_id text NOT NULL CHECK (request_id ~ '^req_[0-9a-f]{32}$'),
    request_digest text NOT NULL,
    principal_issuer text NOT NULL,
    principal_subject text NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN
        ('runtime_link', 'device', 'endpoint_enrollment')),
    entity_id text NOT NULL,
    reason text,
    revoked_at timestamptz NOT NULL,
    UNIQUE (principal_issuer, principal_subject, request_id),
    UNIQUE (principal_issuer, principal_subject, entity_type, entity_id)
);

CREATE TABLE audit_events (
    sequence_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id text NOT NULL UNIQUE CHECK (event_id ~ '^evt_[0-9a-f]{32}$'),
    event_type text NOT NULL,
    outcome text NOT NULL CHECK (outcome IN ('success', 'rejected', 'failure')),
    actor jsonb NOT NULL,
    correlation_id text NOT NULL CHECK (correlation_id ~ '^cor_[0-9a-f]{32}$'),
    request_id text,
    runtime_id text,
    instance_id text,
    device_id text,
    link_id text,
    grant_id text,
    enrollment_id text,
    reason_code text,
    occurred_at timestamptz NOT NULL
);

CREATE TABLE provider_cleanup_jobs (
    sequence_id bigint GENERATED ALWAYS AS IDENTITY UNIQUE,
    job_id text PRIMARY KEY CHECK (job_id ~ '^pcj_[0-9a-f]{32}$'),
    link_id text NOT NULL CHECK (link_id ~ '^lnk_[0-9a-f]{32}$'),
    action text NOT NULL CHECK (action IN ('reconcile_link', 'remove_link', 'remove_enrollment')),
    target_id text NOT NULL CHECK (octet_length(target_id) BETWEEN 20 AND 80),
    active_enrollment_id text CHECK (active_enrollment_id IS NULL OR active_enrollment_id ~ '^enr_[0-9a-f]{32}$'),
    attempt integer NOT NULL DEFAULT 0 CHECK (attempt BETWEEN 0 AND 1000000),
    claim_token text CHECK (claim_token IS NULL OR claim_token ~ '^clm_[0-9a-f]{32}$'),
    next_attempt_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL,
    CHECK (((action = 'reconcile_link' OR action = 'remove_link') AND
            target_id ~ '^lnk_[0-9a-f]{32}$') OR
           (action = 'remove_enrollment' AND target_id ~ '^enr_[0-9a-f]{32}$')),
    CHECK ((action = 'reconcile_link' AND active_enrollment_id IS NOT NULL) OR
           (action <> 'reconcile_link' AND active_enrollment_id IS NULL))
);

CREATE UNIQUE INDEX provider_cleanup_jobs_operation
    ON provider_cleanup_jobs(action, target_id, COALESCE(active_enrollment_id, ''));
CREATE INDEX provider_cleanup_jobs_due ON provider_cleanup_jobs(next_attempt_at);
CREATE INDEX provider_cleanup_jobs_order ON provider_cleanup_jobs(link_id, sequence_id);

CREATE INDEX audit_events_occurred_at ON audit_events(occurred_at, sequence_id);
CREATE INDEX runtime_links_principal ON runtime_links(principal_issuer, principal_subject, runtime_id);
CREATE INDEX bootstrap_grants_device ON bootstrap_grants(principal_issuer, principal_subject, device_id);

ALTER TABLE runtime_link_challenges ADD CHECK (
    request_digest ~ '^[A-Za-z0-9_-]{43}$' AND
    octet_length(principal_issuer) BETWEEN 8 AND 2048 AND principal_issuer ~ '^[!-~]+$' AND
    octet_length(principal_subject) BETWEEN 1 AND 1020 AND principal_subject !~ '[[:cntrl:]]' AND
    jsonb_typeof(runtime_signing_jwk) = 'object' AND pg_column_size(runtime_signing_jwk) <= 2048 AND
    runtime_signing_jwk ?& ARRAY['kty', 'crv', 'x', 'kid'] AND
    runtime_signing_jwk - ARRAY['kty', 'crv', 'x', 'kid', 'use', 'alg'] = '{}'::jsonb AND
    runtime_signing_jwk->>'kty' = 'OKP' AND runtime_signing_jwk->>'crv' = 'Ed25519' AND
    runtime_signing_jwk->>'x' ~ '^[A-Za-z0-9_-]{43}$' AND
    runtime_signing_jwk->>'kid' ~ '^[A-Za-z0-9_-]{16,128}$' AND NOT (runtime_signing_jwk ? 'd') AND
    (NOT (runtime_signing_jwk ? 'use') OR runtime_signing_jwk->>'use' = 'sig') AND
    (NOT (runtime_signing_jwk ? 'alg') OR runtime_signing_jwk->>'alg' = 'EdDSA') AND
    runtime_key_thumbprint ~ '^[A-Za-z0-9_-]{43}$' AND
    jsonb_typeof(runtime_encryption_jwk) = 'object' AND
    pg_column_size(runtime_encryption_jwk) <= 2048 AND
    runtime_encryption_jwk ?& ARRAY['kty', 'crv', 'x', 'kid'] AND
    runtime_encryption_jwk - ARRAY['kty', 'crv', 'x', 'kid', 'use', 'alg'] = '{}'::jsonb AND
    runtime_encryption_jwk->>'kty' = 'OKP' AND runtime_encryption_jwk->>'crv' = 'X25519' AND
    runtime_encryption_jwk->>'x' ~ '^[A-Za-z0-9_-]{43}$' AND
    runtime_encryption_jwk->>'kid' ~ '^[A-Za-z0-9_-]{16,128}$' AND NOT (runtime_encryption_jwk ? 'd') AND
    (NOT (runtime_encryption_jwk ? 'use') OR runtime_encryption_jwk->>'use' = 'enc') AND
    (NOT (runtime_encryption_jwk ? 'alg') OR runtime_encryption_jwk->>'alg' = 'ECDH-ES') AND
    runtime_encryption_key_thumbprint ~ '^[A-Za-z0-9_-]{43}$' AND
    nonce ~ '^[A-Za-z0-9_-]{43}$' AND nonce_hash ~ '^[A-Za-z0-9_-]{43}$' AND
    octet_length(audience) BETWEEN 8 AND 2048 AND audience ~ '^[!-~]+$' AND
    expires_at > created_at AND
    (proof_digest IS NULL OR proof_digest ~ '^[A-Za-z0-9_-]{43}$')
);

ALTER TABLE runtime_links ADD CHECK (
    octet_length(principal_issuer) BETWEEN 8 AND 2048 AND principal_issuer ~ '^[!-~]+$' AND
    octet_length(principal_subject) BETWEEN 1 AND 1020 AND principal_subject !~ '[[:cntrl:]]' AND
    jsonb_typeof(runtime_signing_jwk) = 'object' AND pg_column_size(runtime_signing_jwk) <= 2048 AND
    runtime_signing_jwk ?& ARRAY['kty', 'crv', 'x', 'kid'] AND
    runtime_signing_jwk - ARRAY['kty', 'crv', 'x', 'kid', 'use', 'alg'] = '{}'::jsonb AND
    runtime_signing_jwk->>'kty' = 'OKP' AND runtime_signing_jwk->>'crv' = 'Ed25519' AND
    runtime_signing_jwk->>'x' ~ '^[A-Za-z0-9_-]{43}$' AND
    runtime_signing_jwk->>'kid' ~ '^[A-Za-z0-9_-]{16,128}$' AND
    NOT (runtime_signing_jwk ? 'd') AND
    (NOT (runtime_signing_jwk ? 'use') OR runtime_signing_jwk->>'use' = 'sig') AND
    (NOT (runtime_signing_jwk ? 'alg') OR runtime_signing_jwk->>'alg' = 'EdDSA') AND
    runtime_key_thumbprint ~ '^[A-Za-z0-9_-]{43}$' AND
    jsonb_typeof(runtime_encryption_jwk) = 'object' AND
    pg_column_size(runtime_encryption_jwk) <= 2048 AND
    runtime_encryption_jwk ?& ARRAY['kty', 'crv', 'x', 'kid'] AND
    runtime_encryption_jwk - ARRAY['kty', 'crv', 'x', 'kid', 'use', 'alg'] = '{}'::jsonb AND
    runtime_encryption_jwk->>'kty' = 'OKP' AND runtime_encryption_jwk->>'crv' = 'X25519' AND
    runtime_encryption_jwk->>'x' ~ '^[A-Za-z0-9_-]{43}$' AND
    runtime_encryption_jwk->>'kid' ~ '^[A-Za-z0-9_-]{16,128}$' AND NOT (runtime_encryption_jwk ? 'd') AND
    (NOT (runtime_encryption_jwk ? 'use') OR runtime_encryption_jwk->>'use' = 'enc') AND
    (NOT (runtime_encryption_jwk ? 'alg') OR runtime_encryption_jwk->>'alg' = 'ECDH-ES') AND
    runtime_encryption_key_thumbprint ~ '^[A-Za-z0-9_-]{43}$' AND
    (descriptor IS NULL OR (jsonb_typeof(descriptor) = 'object' AND pg_column_size(descriptor) <= 16384)) AND
    ((status = 'linked' AND unlinked_at IS NULL) OR
     (status = 'unlinked' AND descriptor IS NULL AND unlinked_at IS NOT NULL))
);

ALTER TABLE endpoint_enrollments ADD CHECK (
    request_digest ~ '^[A-Za-z0-9_-]{43}$' AND
    octet_length(principal_issuer) BETWEEN 8 AND 2048 AND principal_issuer ~ '^[!-~]+$' AND
    octet_length(principal_subject) BETWEEN 1 AND 1020 AND principal_subject !~ '[[:cntrl:]]' AND
    (descriptor IS NULL OR (jsonb_typeof(descriptor) = 'object' AND pg_column_size(descriptor) <= 16384)) AND
    ((secret_verifier IS NULL AND secret_expires_at IS NULL) OR
     (secret_verifier ~ '^[A-Za-z0-9_-]{43}$' AND secret_expires_at > created_at AND
      secret_expires_at <= created_at + interval '900 seconds'))
);

ALTER TABLE connect_devices ADD CHECK (
    octet_length(principal_issuer) BETWEEN 8 AND 2048 AND principal_issuer ~ '^[!-~]+$' AND
    octet_length(principal_subject) BETWEEN 1 AND 1020 AND principal_subject !~ '[[:cntrl:]]' AND
    jsonb_typeof(device_signing_jwk) = 'object' AND pg_column_size(device_signing_jwk) <= 2048 AND
    device_signing_jwk ?& ARRAY['kty', 'crv', 'x', 'kid'] AND
    device_signing_jwk - ARRAY['kty', 'crv', 'x', 'kid', 'use', 'alg'] = '{}'::jsonb AND
    device_signing_jwk->>'kty' = 'OKP' AND device_signing_jwk->>'crv' = 'Ed25519' AND
    device_signing_jwk->>'x' ~ '^[A-Za-z0-9_-]{43}$' AND
    device_signing_jwk->>'kid' ~ '^[A-Za-z0-9_-]{16,128}$' AND
    NOT (device_signing_jwk ? 'd') AND
    (NOT (device_signing_jwk ? 'use') OR device_signing_jwk->>'use' = 'sig') AND
    (NOT (device_signing_jwk ? 'alg') OR device_signing_jwk->>'alg' = 'EdDSA') AND
    device_key_thumbprint ~ '^[A-Za-z0-9_-]{43}$'
);

ALTER TABLE bootstrap_grants ADD CHECK (
    request_digest ~ '^[A-Za-z0-9_-]{43}$' AND
    octet_length(principal_issuer) BETWEEN 8 AND 2048 AND principal_issuer ~ '^[!-~]+$' AND
    octet_length(principal_subject) BETWEEN 1 AND 1020 AND principal_subject !~ '[[:cntrl:]]' AND
    jsonb_typeof(device_signing_jwk) = 'object' AND pg_column_size(device_signing_jwk) <= 2048 AND
    device_signing_jwk ?& ARRAY['kty', 'crv', 'x', 'kid'] AND
    device_signing_jwk - ARRAY['kty', 'crv', 'x', 'kid', 'use', 'alg'] = '{}'::jsonb AND
    device_signing_jwk->>'kty' = 'OKP' AND device_signing_jwk->>'crv' = 'Ed25519' AND
    device_signing_jwk->>'x' ~ '^[A-Za-z0-9_-]{43}$' AND
    device_signing_jwk->>'kid' ~ '^[A-Za-z0-9_-]{16,128}$' AND
    NOT (device_signing_jwk ? 'd') AND
    (NOT (device_signing_jwk ? 'use') OR device_signing_jwk->>'use' = 'sig') AND
    (NOT (device_signing_jwk ? 'alg') OR device_signing_jwk->>'alg' = 'EdDSA') AND
    device_key_thumbprint ~ '^[A-Za-z0-9_-]{43}$' AND
    octet_length(audience) BETWEEN 8 AND 2048 AND audience ~ '^[!-~]+$' AND
    client_nonce ~ '^[A-Za-z0-9_-]{43}$' AND cardinality(scopes) BETWEEN 1 AND 8 AND
    scopes <@ ARRAY[
      'runtime:read', 'chat:read', 'chat:write', 'terminal:read', 'terminal:write',
      'repository:read', 'repository:write', 'device:read'
    ]::text[] AND expires_at_seconds > issued_at_seconds AND
    expires_at_seconds - issued_at_seconds <= 300
);

ALTER TABLE revocations ADD CHECK (
    request_digest ~ '^[A-Za-z0-9_-]{43}$' AND
    octet_length(principal_issuer) BETWEEN 8 AND 2048 AND principal_issuer ~ '^[!-~]+$' AND
    octet_length(principal_subject) BETWEEN 1 AND 1020 AND principal_subject !~ '[[:cntrl:]]' AND
    ((entity_type = 'runtime_link' AND entity_id ~ '^lnk_[0-9a-f]{32}$') OR
     (entity_type = 'device' AND entity_id ~ '^dev_[0-9a-f]{32}$') OR
     (entity_type = 'endpoint_enrollment' AND entity_id ~ '^enr_[0-9a-f]{32}$')) AND
    (reason IS NULL OR (octet_length(reason) BETWEEN 1 AND 256 AND reason ~ '^[ -~]+$'))
);

ALTER TABLE audit_events ADD CHECK (
    event_type IN (
      'authentication.succeeded', 'authentication.failed', 'link.challenge_issued',
      'link.challenge_consumed', 'link.challenge_rejected', 'link.created', 'link.unlinked',
      'endpoint.enrollment_reserved', 'endpoint.enrollment_rejected',
      'endpoint.enrolled', 'endpoint.revoked',
      'bootstrap.issued', 'bootstrap.rejected',
      'entity.revoked'
    ) AND jsonb_typeof(actor) = 'object' AND pg_column_size(actor) <= 4096 AND
    (request_id IS NULL OR request_id ~ '^req_[0-9a-f]{32}$') AND
    (runtime_id IS NULL OR runtime_id ~ '^[0-9a-f]{32}$') AND
    (instance_id IS NULL OR instance_id ~ '^[0-9a-f]{32}$') AND
    (device_id IS NULL OR device_id ~ '^dev_[0-9a-f]{32}$') AND
    (link_id IS NULL OR link_id ~ '^lnk_[0-9a-f]{32}$') AND
    (grant_id IS NULL OR grant_id ~ '^grt_[0-9a-f]{32}$') AND
    (enrollment_id IS NULL OR enrollment_id ~ '^enr_[0-9a-f]{32}$') AND
    (reason_code IS NULL OR reason_code ~ '^[a-z][a-z0-9_]{2,63}$')
);
