CREATE TABLE payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    order_id UUID NOT NULL
        REFERENCES orders(id)
        ON DELETE CASCADE,

    amount NUMERIC(10,2) NOT NULL,

    payment_method payment_method NOT NULL,

    payment_status payment_status NOT NULL DEFAULT 'PENDING',

    transaction_reference TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);