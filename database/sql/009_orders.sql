CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    session_id UUID NOT NULL
        REFERENCES table_sessions(id)
        ON DELETE CASCADE,

    order_number TEXT UNIQUE NOT NULL,

    status order_status NOT NULL DEFAULT 'PLACED',

    total_amount NUMERIC(10,2) DEFAULT 0,

    notes TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    order_id UUID NOT NULL
        REFERENCES orders(id)
        ON DELETE CASCADE,

    menu_item_id UUID NOT NULL
        REFERENCES menu_items(id)
        ON DELETE RESTRICT,

    quantity INTEGER NOT NULL DEFAULT 1,

    unit_price NUMERIC(10,2) NOT NULL,

    total_price NUMERIC(10,2) NOT NULL,

    special_instructions TEXT,

    created_at TIMESTAMPTZ DEFAULT NOW()
);