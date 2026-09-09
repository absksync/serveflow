# ServeFlow System Design

## Overview

ServeFlow is a multi-restaurant SaaS platform designed to automate restaurant operations through QR ordering, kitchen workflow management, service requests, and billing.

The platform aims to reduce waiter dependency, improve customer experience, and provide restaurant owners with operational visibility.

---

# System Actors

## Customer

Can:

- Scan QR code
- View menu
- Add items to cart
- Place orders
- Track order status
- Request water
- Request staff assistance
- Request bill
- Pay online

---

## Kitchen Staff

Can:

- View incoming orders
- Accept orders
- Update preparation status
- Mark orders as ready

---

## Manager

Can:

- Monitor active orders
- View service requests
- Manage tables
- Manage staff access

---

## Owner

Can:

- Manage restaurant profile
- Manage branches
- Manage menu
- View analytics
- View revenue reports
- Configure billing

---

# Restaurant Structure

Restaurant
└── Branches
    └── Tables

A single restaurant can have multiple branches.

Each branch maintains its own:

- Tables
- Menu availability
- Orders
- Revenue
- Kitchen workflow

---

# Table Structure

Each table contains:

- Unique ID
- Table Number
- Capacity
- Status
- QR Code

Table Status:

- Available
- Occupied
- Reserved
- Disabled

---

# QR Architecture

Each table receives a unique QR code.

Example:

serveflow.app/table/{table_id}

When scanned:

1. Restaurant identified
2. Branch identified
3. Table identified
4. Menu loaded

Customer never manually selects a table.

---

# Ordering Workflow

Customer scans QR

↓

Menu opens

↓

Items added to cart

↓

Order placed

↓

Kitchen receives order

↓

Order prepared

↓

Order served

↓

Bill generated

↓

Payment completed

---

# Order Lifecycle

PLACED

↓

CONFIRMED

↓

PREPARING

↓

READY

↓

SERVED

↓

PAID

Alternative States:

- CANCELLED
- REFUNDED

---

# Service Request Workflow

Customer may create:

## Water Request

Table requests drinking water.

## Staff Request

Table requests staff assistance.

## Bill Request

Table requests final bill.

All requests appear instantly on the management dashboard.

---

# Payment Workflow

Supported Methods:

- UPI
- Cash
- Card

Payment States:

PENDING

↓

PROCESSING

↓

PAID

Alternative States:

- FAILED
- REFUNDED

---

# Kitchen Workflow

Kitchen dashboard displays:

- New Orders
- Active Orders
- Ready Orders

Kitchen staff can update:

CONFIRMED

↓

PREPARING

↓

READY

---

# Future Scope

Planned features:

- Inventory Management
- WhatsApp Notifications
- n8n Automation
- AI Sales Analytics
- Demand Forecasting
- Multi-Branch Reporting
- Loyalty Programs

---

# MVP Scope

Included:

- QR Ordering
- Order Management
- Kitchen Dashboard
- Service Requests
- Billing
- Payments

Excluded:

- Inventory Management
- AI Features
- Loyalty Programs
- Advanced Analytics