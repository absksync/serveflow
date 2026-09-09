# Database Schema

## Overview

ServeFlow uses PostgreSQL.

The database is designed for multi-restaurant SaaS support.

---

# Tables

## restaurants

Stores restaurant information.

Fields:

- id
- name
- owner_id
- created_at
- updated_at

---

## branches

Stores branch information.

Fields:

- id
- restaurant_id
- name
- address
- phone
- created_at

Relationship:

branches → restaurants

Many branches belong to one restaurant.

---

## users

Stores platform users.

Fields:

- id
- restaurant_id
- branch_id
- name
- email
- role
- created_at

Roles:

- OWNER
- MANAGER
- KITCHEN

---

## tables

Stores restaurant tables.

Fields:

- id
- branch_id
- table_number
- capacity
- status
- qr_code
- created_at

Statuses:

- AVAILABLE
- OCCUPIED
- RESERVED
- DISABLED

---

## menu_categories

Stores menu categories.

Fields:

- id
- branch_id
- name
- created_at

Examples:

- Starters
- Main Course
- Desserts
- Beverages

---

## menu_items

Stores food items.

Fields:

- id
- category_id
- name
- description
- price
- image_url
- is_available
- created_at

---

## orders

Stores customer orders.

Fields:

- id
- branch_id
- table_id
- status
- total_amount
- created_at

Statuses:

- PLACED
- CONFIRMED
- PREPARING
- READY
- SERVED
- PAID
- CANCELLED
- REFUNDED

---

## order_items

Stores items inside orders.

Fields:

- id
- order_id
- menu_item_id
- quantity
- price

---

## service_requests

Stores table requests.

Fields:

- id
- table_id
- request_type
- status
- created_at

Request Types:

- WATER
- STAFF
- BILL

Status:

- PENDING
- COMPLETED

---

## payments

Stores payment records.

Fields:

- id
- order_id
- amount
- payment_method
- payment_status
- transaction_reference
- created_at

Methods:

- UPI
- CASH
- CARD

Statuses:

- PENDING
- PROCESSING
- PAID
- FAILED
- REFUNDED

---

# Relationships

restaurants
│
└── branches
        │
        ├── tables
        ├── menu_categories
        │        │
        │        └── menu_items
        │
        ├── orders
        │      │
        │      └── order_items
        │
        └── service_requests

orders
│
└── payments