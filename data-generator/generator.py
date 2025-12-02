import os
import time
import random
import psycopg2
from faker import Faker
from datetime import datetime
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

fake = Faker()

# Database connection parameters from environment
DB_CONFIG = {
    'host': os.getenv('POSTGRES_HOST', 'postgres'),
    'port': int(os.getenv('POSTGRES_PORT', 5432)),
    'user': os.getenv('POSTGRES_USER', 'postgres'),
    'password': os.getenv('POSTGRES_PASSWORD', 'postgres'),
    'database': os.getenv('POSTGRES_DB', 'testdb')
}

WRITE_INTERVAL = int(os.getenv('WRITE_INTERVAL', 5))

ORDER_STATUSES = ['pending', 'processing', 'shipped', 'delivered', 'cancelled']

def get_db_connection():
    """Create and return a database connection"""
    while True:
        try:
            conn = psycopg2.connect(**DB_CONFIG)
            logger.info("Successfully connected to PostgreSQL")
            return conn
        except psycopg2.OperationalError as e:
            logger.error(f"Failed to connect to PostgreSQL: {e}")
            logger.info("Retrying in 5 seconds...")
            time.sleep(5)

def get_random_customer_id(cursor):
    """Get a random customer ID from the database"""
    cursor.execute("SELECT id FROM customers ORDER BY RANDOM() LIMIT 1")
    result = cursor.fetchone()
    return result[0] if result else None

def insert_order(cursor, customer_id):
    """Insert a new order into the database"""
    try:
        total_amount = round(random.uniform(10.0, 1000.0), 2)
        status = random.choice(ORDER_STATUSES)
        
        cursor.execute("""
            INSERT INTO orders (customer_id, order_date, total_amount, status)
            VALUES (%s, %s, %s, %s)
            RETURNING id
        """, (customer_id, datetime.now(), total_amount, status))
        
        order_id = cursor.fetchone()[0]
        logger.info(f"Inserted order {order_id}: customer={customer_id}, amount=${total_amount}, status={status}")
        return order_id
    except Exception as e:
        logger.error(f"Error inserting order: {e}")
        raise

def update_random_order(cursor):
    """Update a random existing order"""
    try:
        cursor.execute("""
            SELECT id FROM orders 
            WHERE status IN ('pending', 'processing', 'shipped')
            ORDER BY RANDOM() 
            LIMIT 1
        """)
        result = cursor.fetchone()
        
        if result:
            order_id = result[0]
            new_status = random.choice(['processing', 'shipped', 'delivered'])
            
            cursor.execute("""
                UPDATE orders 
                SET status = %s, updated_at = %s 
                WHERE id = %s
            """, (new_status, datetime.now(), order_id))
            
            logger.info(f"Updated order {order_id}: new_status={new_status}")
            return order_id
        else:
            logger.info("No orders available to update")
            return None
    except Exception as e:
        logger.error(f"Error updating order: {e}")
        raise

def insert_customer(cursor):
    """Insert a new customer into the database"""
    try:
        name = fake.name()
        email = fake.unique.email()
        
        cursor.execute("""
            INSERT INTO customers (name, email)
            VALUES (%s, %s)
            RETURNING id
        """, (name, email))
        
        customer_id = cursor.fetchone()[0]
        logger.info(f"Inserted customer {customer_id}: name={name}, email={email}")
        return customer_id
    except psycopg2.IntegrityError:
        logger.warning("Email already exists, skipping customer insert")
        return None
    except Exception as e:
        logger.error(f"Error inserting customer: {e}")
        raise

def main():
    """Main data generator loop"""
    logger.info("Starting data generator service...")
    logger.info(f"Write interval: {WRITE_INTERVAL} seconds")
    logger.info(f"Database: {DB_CONFIG['host']}:{DB_CONFIG['port']}/{DB_CONFIG['database']}")
    
    conn = get_db_connection()
    
    operation_count = 0
    
    try:
        while True:
            try:
                with conn.cursor() as cursor:
                    # Randomly choose an operation
                    operation = random.choices(
                        ['insert_order', 'update_order', 'insert_customer'],
                        weights=[60, 30, 10],  # 60% inserts, 30% updates, 10% new customers
                        k=1
                    )[0]
                    
                    if operation == 'insert_order':
                        customer_id = get_random_customer_id(cursor)
                        if customer_id:
                            insert_order(cursor, customer_id)
                    elif operation == 'update_order':
                        update_random_order(cursor)
                    elif operation == 'insert_customer':
                        insert_customer(cursor)
                    
                    conn.commit()
                    operation_count += 1
                    
                    if operation_count % 10 == 0:
                        logger.info(f"Total operations performed: {operation_count}")
                
            except Exception as e:
                logger.error(f"Error during operation: {e}")
                conn.rollback()
                # Try to reconnect
                try:
                    conn.close()
                except:
                    pass
                conn = get_db_connection()
            
            time.sleep(WRITE_INTERVAL)
            
    except KeyboardInterrupt:
        logger.info("Shutting down data generator...")
    finally:
        conn.close()
        logger.info(f"Data generator stopped. Total operations: {operation_count}")

if __name__ == "__main__":
    main()
