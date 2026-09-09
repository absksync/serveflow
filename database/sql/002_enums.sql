CREATE TYPE user_role AS ENUM (
  'OWNER',
  'MANAGER',
  'KITCHEN'
);

CREATE TYPE table_status AS ENUM (
  'AVAILABLE',
  'OCCUPIED',
  'RESERVED',
  'DISABLED'
);

CREATE TYPE session_status AS ENUM (
  'ACTIVE',
  'CLOSED'
);

CREATE TYPE order_status AS ENUM (
  'PLACED',
  'CONFIRMED',
  'PREPARING',
  'READY',
  'SERVED',
  'PAID',
  'CANCELLED',
  'REFUNDED'
);

CREATE TYPE request_type AS ENUM (
  'WATER',
  'STAFF',
  'BILL'
);

CREATE TYPE request_status AS ENUM (
  'PENDING',
  'COMPLETED'
);

CREATE TYPE payment_method AS ENUM (
  'UPI',
  'CASH',
  'CARD'
);

CREATE TYPE payment_status AS ENUM (
  'PENDING',
  'PROCESSING',
  'PAID',
  'FAILED',
  'REFUNDED'
);