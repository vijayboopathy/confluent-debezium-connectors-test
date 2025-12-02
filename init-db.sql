-- Initialize database with test schema and tables

-- Create a test schema
CREATE SCHEMA IF NOT EXISTS public;

-- Create a sample orders table
CREATE TABLE IF NOT EXISTS orders (
    id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    order_date TIMESTAMP NOT NULL DEFAULT NOW(),
    total_amount DECIMAL(10, 2) NOT NULL,
    status VARCHAR(50) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Create a sample customers table
CREATE TABLE IF NOT EXISTS customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Create an index for better performance
CREATE INDEX IF NOT EXISTS idx_orders_customer_id ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_order_date ON orders(order_date);

-- Insert some initial customers
INSERT INTO customers (name, email) VALUES
    ('John Doe', 'john.doe@example.com'),
    ('Jane Smith', 'jane.smith@example.com'),
    ('Bob Johnson', 'bob.johnson@example.com'),
    ('Alice Williams', 'alice.williams@example.com'),
    ('Charlie Brown', 'charlie.brown@example.com')
ON CONFLICT (email) DO NOTHING;

-- Grant necessary permissions for replication
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE customers REPLICA IDENTITY FULL;

-- Create publication for logical replication
SELECT 'init complete' AS status;
