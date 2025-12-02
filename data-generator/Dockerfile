FROM python:3.11-slim

WORKDIR /app

# Install PostgreSQL client libraries
RUN apt-get update && \
    apt-get install -y libpq-dev gcc && \
    rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY generator.py .

CMD ["python", "-u", "generator.py"]
