CREATE TABLE service_requests (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    session_id UUID NOT NULL
        REFERENCES table_sessions(id)
        ON DELETE CASCADE,

    request_type request_type NOT NULL,

    status request_status NOT NULL DEFAULT 'PENDING',

    notes TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);